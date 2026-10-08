import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'failure.dart';
import 'private_state.dart';
import 'process_identity.dart';

const _label = 'dev.moments.actor-owner';
final _uuid = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
final _containerId = RegExp(r'^[a-f0-9]{64}$');

typedef Docker = String Function(List<String> args);

String _execute(List<String> args) {
  final result = Process.runSync('docker', args);
  if (result.exitCode != 0) {
    throw const ManaFailure(
      'Owned actor container operation failed; inspect its durable record',
    );
  }
  return (result.stdout as String).trim();
}

String uuidV4() {
  final random = Random.secure();
  final bytes = [for (var i = 0; i < 16; i++) random.nextInt(256)];
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// One Docker resource owned through a durable record in [directory]: never
/// the actor's database, browser or UI. A creation failure is not replayable;
/// recovery only stops and removes the owned id.
OwnedContainer allocateOwnedContainer(
  String directory, {
  Docker docker = _execute,
}) {
  final owner = uuidV4();
  final supervisor = processIdentity(pid);
  if (supervisor == null) {
    throw const ManaFailure('Cannot identify actor supervisor');
  }
  final record = <String, Object?>{
    'version': 1,
    'owner': owner,
    'name': 'moments-actor-$owner',
    'supervisor': identityJson(supervisor),
    'phase': 'allocated',
    'containerId': null,
  };
  final file = File(p.join(directory, 'container.json'));
  if (file.existsSync()) {
    throw ManaFailure('Actor container record exists: ${file.path}');
  }
  final handle = openPrivate(file.path);
  try {
    handle
      ..writeStringSync('${jsonEncode(record)}\n')
      ..flushSync();
  } finally {
    handle.closeSync();
  }
  syncDirectory(directory);
  return OwnedContainer._(directory, record, docker);
}

OwnedContainer recoverOwnedContainer(
  String directory, {
  Docker docker = _execute,
}) {
  final file = File(p.join(directory, 'container.json'));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      file.lengthSync() > 16384) {
    throw const ManaFailure('Invalid actor container record');
  }
  final record = (jsonDecode(file.readAsStringSync()) as Map)
      .cast<String, Object?>();
  final supervisor = (record['supervisor'] as Map?)?.cast<String, Object?>();
  final owner = record['owner'], containerId = record['containerId'];
  if (record['version'] != 1 ||
      owner is! String ||
      !_uuid.hasMatch(owner) ||
      record['name'] != 'moments-actor-$owner' ||
      !const [
        'allocated',
        'creating',
        'created',
        'starting',
        'running',
        'stopping',
        'stopped',
      ].contains(record['phase']) ||
      (containerId != null &&
          (containerId is! String || !_containerId.hasMatch(containerId))) ||
      supervisor == null ||
      supervisor['pid'] is! int ||
      (supervisor['pid']! as int) < 1 ||
      !RegExp(r'^\d+$').hasMatch('${supervisor['start'] ?? ''}') ||
      !_uuid.hasMatch('${supervisor['boot'] ?? ''}')) {
    throw const ManaFailure('Invalid actor container record');
  }
  if (sameProcess(supervisor)) {
    throw const ManaFailure(
      'Actor supervisor is still alive; stop it before recovery',
    );
  }
  // Recovered handles cannot resume create/start. No business action is replayed.
  return OwnedContainer._(directory, record, docker, recovered: true);
}

final class OwnedContainer {
  OwnedContainer._(
    this._directory,
    this._record,
    this._docker, {
    this.recovered = false,
  });

  final String _directory;
  final Map<String, Object?> _record;
  final Docker _docker;
  final bool recovered;

  String get name => _record['name']! as String;
  String get phase => _record['phase']! as String;

  void _save(String phase) {
    _record['phase'] = phase;
    savePrivateState(p.join(_directory, 'container.json'), _record);
  }

  Map<String, Object?>? _locate() {
    final ids = _docker([
      'ps',
      '-aq',
      '--no-trunc',
      '--filter',
      'name=^/$name\$',
    ]).split(RegExp(r'\s+')).where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return null;
    if (ids.length != 1 || !_containerId.hasMatch(ids.single)) {
      throw const ManaFailure('Ambiguous actor container identity');
    }
    final actual =
        ((jsonDecode(_docker(['inspect', ids.single])) as List).single as Map)
            .cast<String, Object?>();
    final labels = ((actual['Config'] as Map?)?['Labels'] as Map?) ?? const {};
    if (actual['Id'] != ids.single ||
        actual['Name'] != '/$name' ||
        labels[_label] != _record['owner'] ||
        (_record['containerId'] != null &&
            _record['containerId'] != actual['Id'])) {
      throw const ManaFailure('Actor container ownership changed');
    }
    return actual;
  }

  static bool _running(Map<String, Object?>? actual) =>
      (actual?['State'] as Map?)?['Running'] == true;

  ({bool present, bool running}) inspect() {
    final actual = _locate();
    return (present: actual != null, running: _running(actual));
  }

  void create({
    required String image,
    List<String> command = const [],
    List<String> options = const [],
  }) {
    if (recovered || phase != 'allocated') {
      throw const ManaFailure('Actor creation cannot be replayed');
    }
    // Explicit supported infrastructure options; identity flags are exclusively
    // owned here. Application arguments belong after the image, in command.
    const values = {
      '--tmpfs',
      '--user',
      '--network',
      '--env-file',
      '--mount',
      '-v',
    };
    for (var i = 0; i < options.length; i++) {
      if (options[i] == '--read-only') continue;
      // Hardened packaged services may reduce capabilities, never add them.
      if (options[i] == '--cap-drop' &&
          i + 1 < options.length &&
          options[i + 1] == 'ALL') {
        i++;
        continue;
      }
      if (options[i] == '--security-opt' &&
          i + 1 < options.length &&
          options[i + 1] == 'no-new-privileges') {
        i++;
        continue;
      }
      if (!values.contains(options[i]) ||
          ++i >= options.length ||
          options[i].isEmpty) {
        throw const ManaFailure('Unsupported actor container option');
      }
    }
    if (image.isEmpty || image.startsWith('-')) {
      throw const ManaFailure('Invalid actor container command');
    }
    _save('creating');
    // create never starts the service. A lost acknowledgement may leave an
    // inert container, discoverable by name + owner on explicit recovery.
    final id = _docker([
      'create',
      '--name',
      name,
      '--label',
      '$_label=${_record['owner']}',
      ...options,
      image,
      ...command,
    ]);
    if (!_containerId.hasMatch(id)) {
      throw const ManaFailure('Actor creation did not return a container ID');
    }
    _record['containerId'] = id;
    if (_locate() == null) {
      throw const ManaFailure('Created actor container is missing');
    }
    _save('created');
  }

  void start() {
    if (recovered || phase != 'created') {
      throw const ManaFailure('Actor start cannot be replayed');
    }
    final actual = _locate();
    if (actual == null || _running(actual)) {
      throw const ManaFailure('Actor must exist and be stopped before start');
    }
    _save('starting');
    _docker(['start', actual['Id']! as String]);
    if (!_running(_locate())) {
      throw const ManaFailure('Actor exited during start');
    }
    _save('running');
  }

  void stop({void Function(String id)? beforeRemove}) {
    if (phase == 'stopped' && _locate() == null) return;
    _save('stopping');
    var actual = _locate();
    if (actual != null) {
      // A create acknowledgement may have been lost. Pin the discovered ID
      // durably before the first destructive operation, never just its name.
      if (_record['containerId'] == null) {
        _record['containerId'] = actual['Id'];
        _save('stopping');
      }
      if (_running(actual)) {
        _docker(['stop', '--time', '5', actual['Id']! as String]);
      }
      actual = _locate();
      if (_running(actual)) {
        throw const ManaFailure('Actor container remains running');
      }
      if (actual != null) {
        beforeRemove?.call(actual['Id']! as String);
        _docker(['rm', actual['Id']! as String]);
      }
      if (_locate() != null) {
        throw const ManaFailure('Actor container remains after removal');
      }
    }
    _save('stopped');
  }
}
