import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/runtime.dart' show identityJson, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'flutter_target.dart' show simulatorUdid;
import 'lifecycle.dart' show withInstanceLock;
import 'platform.dart' show processIdentity, sameProcess;

final _uuid = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
bool _port(Object? value) => value is int && value > 0 && value < 65536;
Map<String, Object?> _read(String file) => (jsonDecode(File(file).readAsStringSync()) as Map).cast();

/// Runs `xcrun simctl <args>` and answers its stdout; tests inject a fake.
typedef Simctl = String Function(List<String> args);

String nativeSimctl(List<String> args) {
  final ProcessResult result;
  try {
    result = Process.runSync('xcrun', ['simctl', ...args]);
  } on ProcessException {
    throw const MomentsError('The iOS simulator needs Xcode command line tools (xcrun simctl)');
  }
  if (result.exitCode != 0) {
    throw const MomentsError('iOS simulator operation unconfirmed; boot the same simulator and recover its journal');
  }
  return '${result.stdout}';
}

String _privateDirectory(String directory) {
  Directory(directory).createSync(recursive: true);
  Process.runSync('chmod', ['700', directory]);
  final stat = FileStat.statSync(directory);
  if (FileSystemEntity.isLinkSync(directory) || stat.type != FileSystemEntityType.directory || stat.mode & 0x3f != 0) {
    throw const MomentsError('iOS simulator transport requires an owned private directory');
  }
  return Directory(directory).resolveSymbolicLinksSync();
}

/// The booted simulator [udid] and its boot: `lastBootedAt` as a UUID, so a
/// reboot of the same simulator releases an old claim.
Map<String, Object?> _identity(Simctl simctl, String udid) {
  final Object? listed;
  try {
    listed = jsonDecode(simctl(['list', 'devices', '--json']));
  } on FormatException {
    throw const MomentsError('Unrecognized simctl device inventory');
  }
  final runtimes = listed is Map ? listed['devices'] : null;
  if (runtimes is! Map) throw const MomentsError('Unrecognized simctl device inventory');
  for (final MapEntry(key: runtime, value: devices) in runtimes.entries) {
    for (final device in devices is List ? devices : const []) {
      if (device is! Map || device['udid'] != udid) continue;
      final booted = device['lastBootedAt'];
      if (device['state'] != 'Booted' || booted is! String || !'$runtime'.contains('.iOS-')) {
        throw const MomentsError('A booted iOS simulator is required; boot it with xcrun simctl boot <udid>');
      }
      final hex = sha256.convert(utf8.encode('$udid:$booted')).toString();
      return {
        'boot':
            '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}',
        'runtime': '$runtime',
      };
    }
  }
  throw const MomentsError('No iOS simulator with that UDID; list them with xcrun simctl list devices');
}

Map<String, Object?> _validate(Map<String, Object?> state, String directory) {
  final ports = state['ports'];
  final supervisor = state['supervisor'];
  if (state['version'] != 1 ||
      !_uuid.hasMatch('${state['owner'] ?? ''}') ||
      !simulatorUdid(state['device']) ||
      !_uuid.hasMatch('${state['boot'] ?? ''}') ||
      state['directory'] != directory ||
      !const ['planned', 'claimed', 'ready', 'disposed'].contains(state['phase']) ||
      ports is! List ||
      ports.isEmpty ||
      ports.length > 16 ||
      ports.any((port) => !_port(port)) ||
      supervisor is! Map ||
      supervisor['pid'] is! int ||
      !RegExp(r'^\d+$').hasMatch('${supervisor['start'] ?? ''}') ||
      !_uuid.hasMatch('${supervisor['boot'] ?? ''}')) {
    throw const MomentsError('Invalid iOS simulator transport journal');
  }
  return state;
}

/// One run's use of a booted iOS simulator. The simulator shares the Mac's
/// network, so the app reaches the API and bridge on loopback with no
/// forwarding (unlike `adb reverse`); what the transport owns is the claim:
/// one Mana run per simulator, across workspaces and after a supervisor's
/// death, journaled before every change. It never boots, erases or installs.
final class IosTransport {
  IosTransport({
    required String directory,
    required this.device,
    required this.ports,
    String? owner,
    this.simctl = nativeSimctl,
    String? claims,
  }) : owner = owner ?? uuidV4() {
    if (!simulatorUdid(device) ||
        !_uuid.hasMatch(this.owner) ||
        ports.isEmpty ||
        ports.length > 16 ||
        ports.any((port) => !_port(port)) ||
        ports.toSet().length != ports.length) {
      throw const MomentsError('Explicit iOS simulator UDID and unique TCP ports required');
    }
    this.directory = _privateDirectory(directory);
    this.claims = _privateDirectory(
      claims ?? p.join(Platform.environment['HOME']!, '.cache', 'mana', 'ios-simulators'),
    );
    _file = p.join(this.directory, 'transport.json');
    _claim = p.join(this.claims, '${sha256.convert(utf8.encode(device))}.json');
  }

  final String device;
  final List<int> ports;
  final String owner;
  final Simctl simctl;
  late final String directory, claims, _file, _claim;

  void _save(Map<String, Object?> state) => savePrivateState(_file, state);

  /// A claim left by a run whose simulator has since rebooted no longer
  /// holds it; one from the same boot does.
  void _releaseStaleClaim(String boot) {
    if (!File(_claim).existsSync()) return;
    final claim = _read(_claim);
    if (claim['device'] == device && claim['boot'] != boot) {
      File(_claim).deleteSync();
      syncDirectory(claims);
    }
  }

  Future<Map<String, Object?>> start() => withInstanceLock(directory, () async {
    if (File(_file).existsSync()) {
      throw const MomentsError('iOS simulator transport already has a journal; recover it before another run');
    }
    final identified = _identity(simctl, device);
    final supervisor = processIdentity(pid);
    if (supervisor == null) throw const MomentsError('Cannot establish iOS supervisor identity');
    final state = <String, Object?>{
      'version': 1,
      'owner': owner,
      'device': device,
      'directory': directory,
      'supervisor': identityJson(supervisor),
      ...identified,
      'ports': ports,
      'phase': 'planned',
    };
    _save(state);
    _releaseStaleClaim(identified['boot']! as String);
    final pending = p.join(claims, 'claim-$owner-${uuidV4()}.json');
    savePrivateState(pending, {
      'version': 1,
      'owner': owner,
      'device': device,
      'directory': directory,
      'boot': identified['boot'],
    });
    try {
      final link = Process.runSync('ln', ['--', pending, _claim]);
      if (link.exitCode != 0) {
        throw const MomentsError('iOS simulator is claimed by another run; it was not used');
      }
    } finally {
      File(pending).deleteSync();
    }
    syncDirectory(claims);
    state['phase'] = 'claimed';
    _save(state);
    if (_identity(simctl, device)['boot'] != state['boot']) {
      throw const MomentsError('iOS simulator rebooted before the claim was confirmed; recover this run');
    }
    state['phase'] = 'ready';
    _save(state);
    return state;
  });

  Future<Map<String, Object?>> close() => withInstanceLock(directory, () async {
    final state = _validate(_read(_file), directory);
    if (state['device'] != device || state['owner'] != owner) {
      throw const MomentsError('iOS recovery identity differs from the recorded run');
    }
    if (File(_claim).existsSync()) {
      final claim = _read(_claim);
      if (claim['owner'] == owner && claim['directory'] == directory) {
        File(_claim).deleteSync();
        syncDirectory(claims);
      }
    }
    state['phase'] = 'disposed';
    _save(state);
    return state;
  });
}

Future<Map<String, Object?>> recoverIosTransport(
  String directory, {
  Simctl simctl = nativeSimctl,
  String? claims,
}) async {
  final real = Directory(directory).resolveSymbolicLinksSync();
  final state = _validate(_read(p.join(directory, 'transport.json')), real);
  if (state['phase'] != 'disposed' && sameProcess((state['supervisor']! as Map).cast())) {
    throw const MomentsError('iOS transport supervisor is still alive; close it through its owner');
  }
  return IosTransport(
    directory: directory,
    device: state['device']! as String,
    ports: (state['ports']! as List).cast<int>(),
    owner: state['owner']! as String,
    simctl: simctl,
    claims: claims,
  ).close();
}
