import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/runtime.dart' show identityJson, openPrivate, uuidV4;
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'errors.dart';
import 'services.dart' show ServiceLifecycle;
import 'flutter_target.dart';
import 'platform.dart';

export 'package:mana/runtime.dart' show momentDockerLabels;
export 'platform.dart' show processIdentity, sameProcess, signalOwnedProcess;

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

/// A lock that survives neither process death nor host restart: no
/// stale-lock TTL or PID-only heuristic can let two down/up operations race on
/// the database (`HostPlatform.lock`).
Future<Future<void> Function()> acquireInstanceLock(String directory) =>
    host.lock(p.join(directory, '.operation.lock'));

Future<T> withInstanceLock<T>(String directory, Future<T> Function() operation) async {
  final release = await acquireInstanceLock(directory);
  try {
    return await operation();
  } finally {
    await release();
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
  final android = value['android'] as Map?, ios = value['ios'] as Map?;
  if (value['version'] == 2 && value.containsKey('android'))
    throw const MomentsError('Android ownership requires lifecycle version 3');
  if (value['version'] == 2 && value.containsKey('ios'))
    throw const MomentsError('iOS simulator ownership requires lifecycle version 3');
  if (value['version'] == 3 && ios != null) {
    final iosPorts = ios['ports'];
    if (android != null ||
        !simulatorUdid(ios['device']) ||
        iosPorts is! List ||
        iosPorts.isEmpty ||
        iosPorts.toSet().length != iosPorts.length ||
        iosPorts.any((port) => !ports.contains(port))) {
      throw const MomentsError('Invalid iOS simulator lifecycle ownership');
    }
  } else if (value['version'] == 3) {
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
    Map<String, Object?>? ios,
  }) {
    if (File(p.join(directory, '.reset.json')).existsSync()) {
      throw const MomentsError('Interrupted reset must finish with moments reset --discard-data before startup');
    }
    final file = p.join(directory, 'running.json');
    final supervisor = processIdentity(pid);
    if (supervisor == null) throw const MomentsError('Cannot establish supervisor process identity');
    final id = instanceId ?? uuidV4();
    final state = <String, Object?>{
      'version': android != null || ios != null ? 3 : 2,
      'runId': uuidV4(),
      'instanceId': id,
      'workspace': workspaceIdentity(project),
      'supervisor': identityJson(supervisor),
      'ports': ports,
      'databaseStarted': false,
      'processes': <Object?>[],
      'android': ?android,
      'ios': ?ios,
    };
    validateLifecycle(state, project);
    if (File(file).existsSync())
      throw MomentsError(
        'The instance is already running ($file): moments open <name> switches Moments in it; moments down stops it.',
      );
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
    final listed = host.processes();
    if (listed == null) return;
    final processes = {for (final MapEntry(:key, :value) in listed.entries) key: identityJson(value)};
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
