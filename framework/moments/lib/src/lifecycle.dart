import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson, openPrivate, processIdentity, uuidV4;
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'errors.dart';
import 'services.dart' show ServiceLifecycle;
import 'flutter_target.dart';

export 'package:mana/mana.dart' show momentDockerLabels, processIdentity, sameProcess, signalOwnedProcess;

final _uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');

String flutterTemporaryDirectory(String directory, String runId) {
  if (!_uuid.hasMatch(runId)) throw const MomentsError('Invalid temporary resource ownership');
  return p.join(directory, 'tmp', 'flutter-$runId');
}

/// Only after owned processes have stopped. Never prune shared system /tmp.
void clearFlutterTemporaryFiles(String directory, String runId) {
  final path = Directory(flutterTemporaryDirectory(directory, runId));
  if (path.existsSync()) path.deleteSync(recursive: true);
}

String workspaceIdentity(String project) => hashText(Directory(project).resolveSymbolicLinksSync());

/// A kernel lock that survives neither process death nor host restart: no
/// stale-lock TTL or PID-only heuristic can let two down/up operations race on
/// the database. `flock(1)` holds it in a child that lives until released.
Future<Future<void> Function()> acquireInstanceLock(String directory) async {
  if (!Platform.isLinux) throw const MomentsError('Instance lifecycle currently requires Linux /proc and flock');
  final Process child;
  try {
    child = await Process.start('flock', [
      '--exclusive',
      '--nonblock',
      p.join(directory, '.operation.lock'),
      'sh',
      '-c',
      'echo locked; read _ || true',
    ]);
  } on ProcessException {
    throw const MomentsError('Cannot start flock for instance ownership');
  }
  final exited = child.exitCode;
  final locked = Completer<void>();
  child.stdout.transform(utf8.decoder).listen((chunk) {
    if (chunk.contains('locked') && !locked.isCompleted) locked.complete();
  });
  child.stderr.drain<void>();
  unawaited(
    exited.then((_) {
      if (!locked.isCompleted)
        locked.completeError(const MomentsError('Another instance lifecycle operation is running'));
    }),
  );
  try {
    await locked.future;
  } on Object {
    await child.stdin.close().catchError((_) {});
    await exited;
    rethrow;
  }
  var released = false;
  return () async {
    if (!released) {
      released = true;
      await child.stdin.close().catchError((_) {});
    }
    await exited;
  };
}

Future<T> withInstanceLock<T>(String directory, Future<T> Function() operation) async {
  final release = await acquireInstanceLock(directory);
  try {
    return await operation();
  } finally {
    await release();
  }
}

void assertNoManagedSession(String directory) {
  if (File(p.join(directory, 'preparation.json')).existsSync()) {
    throw const MomentsError(
      'A preparation owns this consumer; finish it or use moments recover --preparation before another lifecycle operation',
    );
  }
  if (File(p.join(directory, 'materialization.json')).existsSync()) {
    throw const MomentsError(
      'A materialization session owns this consumer; close it or use moments recover --session before another lifecycle operation',
    );
  }
}

bool _validProcess(Object? record) =>
    record is Map &&
    record['pid'] is int &&
    (record['pid'] as int) >= 1 &&
    RegExp(r'^\d+$').hasMatch('${record['start'] ?? ''}') &&
    _uuid.hasMatch('${record['boot'] ?? ''}');

Map<String, Object?> validateLifecycle(Object? raw, String project) {
  final value = raw is Map ? raw.cast<String, Object?>() : null;
  final ports = value?['ports'];
  if (value == null ||
      ![2, 3].contains(value['version']) ||
      !_uuid.hasMatch('${value['runId'] ?? ''}') ||
      !_uuid.hasMatch('${value['instanceId'] ?? ''}') ||
      value['workspace'] != workspaceIdentity(project) ||
      value['processes'] is! List ||
      (value['processes'] as List).length > 4096 ||
      value['databaseStarted'] is! bool ||
      ports is! List ||
      ports.any((port) => port is! int || port < 1 || port > 65535)) {
    throw const MomentsError('Instance has no valid recovery ownership; stop its original launcher before upgrading');
  }
  final android = value['android'] as Map?;
  if (value['version'] == 2 && value.containsKey('android'))
    throw const MomentsError('Android ownership requires lifecycle version 3');
  if (value['version'] == 3) {
    final androidPorts = android?['ports'];
    if (!androidSerial(android?['device']) ||
        androidPorts is! List ||
        androidPorts.isEmpty ||
        androidPorts.toSet().length != androidPorts.length ||
        androidPorts.any((port) => !ports.contains(port))) {
      throw const MomentsError('Invalid Android lifecycle ownership');
    }
  }
  for (final record in [value['supervisor'], ...(value['processes']! as List)]) {
    if (!_validProcess(record)) throw const MomentsError('Invalid process ownership record');
  }
  return value;
}

/// The durable record (`running.json`) of one launcher run: its identity, the
/// ports it owns and every process it started, rescanned for descendants so a
/// later `down` can stop exactly those.
final class Lifecycle implements ServiceLifecycle {
  Lifecycle._(this._file, this.state, this._directory, this.instanceId);

  factory Lifecycle.create({
    required String project,
    required String directory,
    String? instanceId,
    List<int> ports = const [],
    Map<String, Object?>? android,
  }) {
    if (File(p.join(directory, '.reset.json')).existsSync()) {
      throw const MomentsError('Interrupted reset must finish with moments reset --discard-data before startup');
    }
    final file = p.join(directory, 'running.json');
    final supervisor = processIdentity(pid);
    if (supervisor == null) throw const MomentsError('Cannot establish supervisor process identity');
    final id = instanceId ?? uuidV4();
    final state = <String, Object?>{
      'version': android != null ? 3 : 2,
      'runId': uuidV4(),
      'instanceId': id,
      'workspace': workspaceIdentity(project),
      'supervisor': identityJson(supervisor),
      'ports': ports,
      'databaseStarted': false,
      'processes': <Object?>[],
      'android': ?android,
    };
    validateLifecycle(state, project);
    if (File(file).existsSync()) throw MomentsError('Instance already running: $file');
    final handle = openPrivate(file);
    try {
      handle.writeStringSync('${const JsonEncoder.withIndent('  ').convert(state)}\n');
    } finally {
      handle.closeSync();
    }
    final lifecycle = Lifecycle._(file, state, directory, id);
    lifecycle._timer = Timer.periodic(const Duration(milliseconds: 500), (_) => lifecycle.scan());
    return lifecycle;
  }

  final String _file;
  final Map<String, Object?> state;
  final String _directory;
  final String instanceId;
  final _tracked = <int, Map<String, Object?>>{};
  var _closed = false;
  Timer? _timer;

  void _save() {
    if (_closed) return;
    state['processes'] = [..._tracked.values];
    final handle = openPrivate('$_file.tmp');
    try {
      handle.writeStringSync('${const JsonEncoder.withIndent('  ').convert(state)}\n');
    } finally {
      handle.closeSync();
    }
    File('$_file.tmp').renameSync(_file);
  }

  void scan() {
    if (_closed || _tracked.isEmpty) return;
    final processes = <int, Map<String, Object?>>{};
    for (final entry in Directory('/proc').listSync(followLinks: false)) {
      final id = int.tryParse(p.basename(entry.path));
      if (id == null) continue;
      final value = processIdentity(id);
      if (value != null) processes[id] = identityJson(value);
    }
    var changed = false;
    for (final MapEntry(key: id, value: record) in [..._tracked.entries]) {
      final current = processes[id];
      if (current == null || current['start'] != record['start'] || current['boot'] != record['boot']) {
        _tracked.remove(id);
        changed = true;
      }
    }
    bool added;
    do {
      added = false;
      for (final MapEntry(key: id, value: value) in processes.entries) {
        if (!_tracked.containsKey(id) && _tracked.containsKey(value['parent'])) {
          _tracked[id] = {...value, 'role': _tracked[value['parent']]!['role']};
          added = true;
          changed = true;
        }
      }
    } while (added);
    if (changed) _save();
  }

  void claimDatabase() {
    state['databaseStarted'] = true;
    _save();
  }

  @override
  Map<String, String> environment() => {
    'MANA_RESOURCE_OWNER': instanceId,
    'MANA_RESOURCE_RUN': state['runId']! as String,
    'MANA_RESOURCE_WORKSPACE': state['workspace']! as String,
  };

  @override
  void track(Process child, String role) {
    final value = processIdentity(child.pid);
    if (value != null) {
      _tracked[value.pid] = {...identityJson(value), 'role': role};
      _save();
    }
  }

  Map<String, Object?> freeze() {
    scan();
    _closed = true;
    _timer?.cancel();
    return state;
  }

  void finish() {
    _closed = true;
    _timer?.cancel();
    final file = File(_file);
    if (file.existsSync() && (jsonDecode(file.readAsStringSync()) as Map)['runId'] == state['runId']) {
      clearFlutterTemporaryFiles(_directory, state['runId']! as String);
      file.deleteSync();
    }
  }
}
