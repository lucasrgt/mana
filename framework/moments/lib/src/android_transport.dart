import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart'
    show identityJson, processIdentity, sameProcess, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'json.dart';
import 'lifecycle.dart' show withInstanceLock;

final _uuid = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
final _serial = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$');
bool _port(Object? value) => value is int && value > 0 && value < 65536;
Map<String, Object?> _read(String file) => (jsonDecode(File(file).readAsStringSync()) as Map).cast();

typedef Adb = String Function(List<String> args);

String nativeAdb(List<String> args) {
  final result = Process.runSync('adb', args);
  if (result.exitCode != 0) {
    throw const MomentsError(
      'Android transport operation unconfirmed; reconnect the same device and recover its journal',
    );
  }
  return (result.stdout as String).trim();
}

String _privateDirectory(String directory) {
  Directory(directory).createSync(recursive: true);
  Process.runSync('chmod', ['700', directory]);
  final stat = FileStat.statSync(directory);
  if (FileSystemEntity.isLinkSync(directory) || stat.type != FileSystemEntityType.directory || stat.mode & 0x3f != 0) {
    throw const MomentsError('Android transport requires an owned private directory');
  }
  return Directory(directory).resolveSymbolicLinksSync();
}

Map<String, Object?> _identity(Adb adb, String device) {
  final boot = adb(['-s', device, 'shell', 'cat', '/proc/sys/kernel/random/boot_id']).trim();
  final sdk = adb(['-s', device, 'shell', 'getprop', 'ro.build.version.sdk']).trim();
  if (!_uuid.hasMatch(boot) || !RegExp(r'^\d+$').hasMatch(sdk) || int.parse(sdk) < 24) {
    throw const MomentsError('An online Android API 24+ device is required');
  }
  return {'boot': boot, 'sdk': int.parse(sdk)};
}

List<({String remote, String local})> _mappings(Adb adb, String device) => [
  for (final line in adb(['-s', device, 'reverse', '--list']).split(RegExp(r'\r?\n')).where((l) => l.trim().isNotEmpty))
    () {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 3) throw const MomentsError('Unrecognized ADB reverse inventory');
      return (remote: fields[1], local: fields[2]);
    }(),
];

Map<String, Object?> _validate(Map<String, Object?> state, String directory) {
  final ports = state['ports'];
  if (state['version'] != 1 ||
      !_uuid.hasMatch('${state['owner'] ?? ''}') ||
      !_serial.hasMatch('${state['device'] ?? ''}') ||
      !_uuid.hasMatch('${state['boot'] ?? ''}') ||
      state['directory'] != directory ||
      !const ['planned', 'claimed', 'ready', 'disposed'].contains(state['phase']) ||
      ports is! List ||
      ports.isEmpty ||
      ports.length > 16 ||
      ports.any(
        (x) =>
            x is! Map ||
            !_port(x['port']) ||
            !const ['planned', 'creating', 'created', 'released'].contains(x['phase']),
      ) ||
      ports.map((x) => (x as Map)['port']).toSet().length != ports.length) {
    throw const MomentsError('Invalid Android transport journal');
  }
  final supervisor = state['supervisor'];
  if (supervisor is! Map ||
      supervisor['pid'] is! int ||
      (supervisor['pid'] as int) < 1 ||
      !RegExp(r'^\d+$').hasMatch('${supervisor['start'] ?? ''}') ||
      !_uuid.hasMatch('${supervisor['boot'] ?? ''}')) {
    throw const MomentsError('Invalid Android supervisor identity');
  }
  return state;
}

/// ADB reverse ports owned by one run, journaled before every change. A claim
/// excludes other Mana runs across workspaces, including after process death.
/// This is cooperative local ownership: manual ADB replacement with the exact
/// same endpoints is not distinguishable. Never uses --remove-all or rebind.
final class AndroidTransport {
  AndroidTransport({
    required String directory,
    required this.device,
    required this.ports,
    String? owner,
    this.adb = nativeAdb,
    String? claims,
  }) : owner = owner ?? uuidV4() {
    if (!_serial.hasMatch(device) ||
        !_uuid.hasMatch(this.owner) ||
        ports.isEmpty ||
        ports.length > 16 ||
        ports.any((port) => !_port(port)) ||
        ports.toSet().length != ports.length) {
      throw const MomentsError('Explicit Android serial and unique TCP ports required');
    }
    this.directory = _privateDirectory(directory);
    this.claims = _privateDirectory(
      claims ?? p.join(Platform.environment['HOME']!, '.cache', 'mana', 'android-transports'),
    );
    _file = p.join(this.directory, 'transport.json');
    _claim = p.join(this.claims, '${sha256.convert(utf8.encode(device))}.json');
  }

  final String device;
  final List<int> ports;
  final String owner;
  final Adb adb;
  late final String directory, claims, _file, _claim;

  void _save(Map<String, Object?> state) => savePrivateState(_file, state);

  bool _ownClaim(Map<String, Object?> state) {
    if (!File(_claim).existsSync()) return false;
    final claim = _read(_claim);
    if (claim['owner'] != state['owner'] || claim['directory'] != directory || claim['device'] != device) {
      throw const MomentsError('Android device is claimed by another run; it was not modified');
    }
    return true;
  }

  List<Map<String, Object?>> _ports(Map<String, Object?> state) =>
      (state['ports']! as List).cast<Map<String, Object?>>();

  Map<String, Object?> inspectOwnership() {
    final state = _validate(_read(_file), directory);
    if (state['owner'] != owner ||
        state['device'] != device ||
        !jsonEqual([for (final x in _ports(state)) x['port']], ports) ||
        !const ['claimed', 'ready'].contains(state['phase']) ||
        !_ownClaim(state)) {
      throw const MomentsError('Android transport ownership is not active');
    }
    return {...state, 'currentBoot': _identity(adb, device)['boot']};
  }

  Future<Map<String, Object?>> start() => withInstanceLock(directory, () async {
    if (File(_file).existsSync()) {
      throw const MomentsError('Android transport already has a journal; recover it before allocating another run');
    }
    final identified = _identity(adb, device);
    final before = _mappings(adb, device);
    if (ports.any((port) => before.any((m) => m.remote == 'tcp:$port'))) {
      throw const MomentsError('Android reverse port is already occupied; it was not rebound');
    }
    final supervisor = processIdentity(pid);
    if (supervisor == null) throw const MomentsError('Cannot establish Android supervisor identity');
    final state = <String, Object?>{
      'version': 1,
      'owner': owner,
      'device': device,
      'directory': directory,
      'supervisor': identityJson(supervisor),
      ...identified,
      'phase': 'planned',
      'ports': [
        for (final port in ports) {'port': port, 'phase': 'planned'},
      ],
    };
    _save(state);
    // Publish a complete immutable claim exclusively, even if killed between
    // publication and the next journal checkpoint.
    final pending = p.join(claims, 'claim-$owner-${uuidV4()}.json');
    savePrivateState(pending, {'version': 1, 'owner': owner, 'device': device, 'directory': directory});
    try {
      final link = Process.runSync('ln', ['--', pending, _claim]);
      if (link.exitCode != 0) throw const MomentsError('Android device is claimed by another run; it was not modified');
    } finally {
      File(pending).deleteSync();
    }
    syncDirectory(claims);
    state['phase'] = 'claimed';
    _save(state);
    for (final entry in _ports(state)) {
      if (_identity(adb, device)['boot'] != state['boot'])
        throw const MomentsError('Android rebooted during allocation; recover this run');
      if (_mappings(adb, device).any((m) => m.remote == 'tcp:${entry['port']}')) {
        throw const MomentsError('Android reverse port changed during allocation; recover this run');
      }
      entry['phase'] = 'creating';
      _save(state);
      adb(['-s', device, 'reverse', '--no-rebind', 'tcp:${entry['port']}', 'tcp:${entry['port']}']);
      entry['phase'] = 'created';
      _save(state);
    }
    if (_identity(adb, device)['boot'] != state['boot']) {
      throw const MomentsError('Android rebooted before allocation could be confirmed');
    }
    final actual = _mappings(adb, device);
    if (!_ports(
      state,
    ).every((x) => actual.any((m) => m.remote == 'tcp:${x['port']}' && m.local == 'tcp:${x['port']}'))) {
      throw const MomentsError('Android reverse allocation not confirmed');
    }
    state['phase'] = 'ready';
    _save(state);
    return state;
  });

  void _dropOwnClaim() {
    if (!File(_claim).existsSync()) return;
    final claim = _read(_claim);
    if (claim['owner'] == owner && claim['directory'] == directory) {
      File(_claim).deleteSync();
      syncDirectory(claims);
    }
  }

  Future<Map<String, Object?>> close() => withInstanceLock(directory, () async {
    final state = _validate(_read(_file), directory);
    if (state['device'] != device ||
        state['owner'] != owner ||
        !jsonEqual([for (final x in _ports(state)) x['port']], ports)) {
      throw const MomentsError('Android recovery identity differs from the recorded run');
    }
    if (state['phase'] == 'disposed') {
      _dropOwnClaim();
      return state;
    }
    // A refused claim cannot have allocated endpoints. Leave the other owner.
    if (state['phase'] == 'planned' && _ports(state).every((x) => x['phase'] == 'planned')) {
      _dropOwnClaim();
      state['phase'] = 'disposed';
      _save(state);
      return state;
    }
    if (!_ownClaim(state)) throw const MomentsError('Android claim missing; ownership retained for inspection');
    final current = _identity(adb, device);
    final allocated = _ports(state).where((x) => const ['creating', 'created'].contains(x['phase'])).toList();
    if (current['boot'] == state['boot']) {
      // Check all conflicts before removing any mapping.
      final actual = _mappings(adb, device);
      for (final entry in allocated) {
        final found = actual.where((m) => m.remote == 'tcp:${entry['port']}').firstOrNull;
        if (found != null && found.local != 'tcp:${entry['port']}') {
          throw const MomentsError('Android reverse mapping was replaced; it was not removed');
        }
      }
      for (final entry in allocated) {
        if (_identity(adb, device)['boot'] != state['boot'])
          throw const MomentsError('Android rebooted during cleanup; recover this run again');
        final found = _mappings(adb, device).where((m) => m.remote == 'tcp:${entry['port']}').firstOrNull;
        if (found != null && found.local != 'tcp:${entry['port']}')
          throw const MomentsError('Android reverse mapping changed during cleanup');
        if (found != null) adb(['-s', device, 'reverse', '--remove', 'tcp:${entry['port']}']);
        entry['phase'] = 'released';
        _save(state);
      }
    } else {
      state['rebooted'] = true;
    }
    state['phase'] = 'disposed';
    _save(state);
    File(_claim).deleteSync();
    syncDirectory(claims);
    return state;
  });
}

Future<Map<String, Object?>> recoverAndroidTransport(String directory, {Adb adb = nativeAdb, String? claims}) {
  final real = Directory(directory).resolveSymbolicLinksSync();
  final state = _validate(_read(p.join(directory, 'transport.json')), real);
  if (state['phase'] != 'disposed' && sameProcess((state['supervisor']! as Map).cast())) {
    throw const MomentsError('Android transport supervisor is still alive; close it through its owner');
  }
  return AndroidTransport(
    directory: directory,
    device: state['device']! as String,
    ports: [for (final x in (state['ports']! as List).cast<Map>()) x['port'] as int],
    owner: state['owner']! as String,
    adb: adb,
    claims: claims,
  ).close();
}
