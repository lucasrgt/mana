import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson, processIdentity, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'lifecycle.dart';
import 'private_fs.dart';
import 'suite.dart' show selfCommand;

final _invocation = RegExp(r'^[a-f0-9]{32}$');
const _properties = [
  'LoadState',
  'ActiveState',
  'Description',
  'InvocationID',
  'MainPID',
  'KillMode',
  'Restart',
  'Transient',
  'ControlGroup',
];

/// Hidden subcommand that runs inside the registered user service.
const ownedProcessWorker = '__owned-process';

String _description(Map<String, Object?> record) => 'Mana Moments actor ${record['owner']}';

Map<String, Object?> _readRecord(String dir) {
  final record = readJsonObject(p.join(dir, 'process.json'), 16384, 'Invalid actor process record');
  final supervisor = record['supervisor'];
  if (record['version'] != 1 ||
      !isUuid(record['owner']) ||
      record['unit'] != 'mana-moments-${record['owner']}.service' ||
      !const ['allocated', 'starting', 'running', 'attention', 'stopping', 'stopped'].contains(record['phase']) ||
      (record['invocation'] != null && !_invocation.hasMatch('${record['invocation']}')) ||
      supervisor is! Map ||
      supervisor['pid'] is! int ||
      (supervisor['pid']! as int) < 1 ||
      !RegExp(r'^\d+$').hasMatch('${supervisor['start'] ?? ''}') ||
      !isUuid(supervisor['boot'])) {
    throw const MomentsError('Invalid actor process identity');
  }
  return record;
}

Map<String, String>? _unitState(Map<String, Object?> record) {
  final result = Process.runSync('systemctl', [
    '--user',
    'show',
    '--property=${_properties.join(',')}',
    '--',
    record['unit']! as String,
  ]);
  final value = {
    for (final line in (result.stdout as String).trim().split('\n'))
      if (line.contains('=')) line.substring(0, line.indexOf('=')): line.substring(line.indexOf('=') + 1),
  };
  if (value['LoadState'] == 'not-found') return null;
  if (result.exitCode != 0) {
    throw const MomentsError('User service manager unavailable; actor process ownership retained');
  }
  if (value['Description'] != _description(record) ||
      value['Transient'] != 'yes' ||
      value['KillMode'] != 'control-group' ||
      value['Restart'] != 'no' ||
      (record['invocation'] != null && value['InvocationID'] != record['invocation'])) {
    throw const MomentsError('Actor process unit ownership changed');
  }
  return value;
}

bool _populated(Map<String, String>? state) {
  final group = state?['ControlGroup'];
  if (group == null || group.isEmpty) return false;
  // Only the inspected unit's cgroup, never a caller-provided process tree.
  final path = p.normalize(p.join('/sys/fs/cgroup', '.$group'));
  if (!path.startsWith('/sys/fs/cgroup/')) throw const MomentsError('Invalid actor control group');
  final file = File(p.join(path, 'cgroup.events'));
  return file.existsSync() && RegExp(r'^populated 1$', multiLine: true).hasMatch(file.readAsStringSync());
}

/// A command contained in its own transient user unit. The unit is
/// registered before the command may start, so a dead supervisor never leaves
/// an unowned process tree.
final class OwnedProcess {
  OwnedProcess._(this._dir, this._record, {this.recovered = false, List<String>? worker}) : _worker = worker;

  final String _dir;
  final Map<String, Object?> _record;
  final bool recovered;
  final List<String>? _worker;
  Process? _child;
  Future<int>? _ended;
  Future<void>? _closing;

  String get unit => _record['unit']! as String;
  String get phase => _record['phase']! as String;

  void _save(String phase) {
    _record['phase'] = phase;
    savePrivateState(p.join(_dir, 'process.json'), _record);
  }

  ({bool present, bool running, String state}) inspect() {
    final state = _unitState(_record);
    return (
      present: state != null,
      running: state != null && _populated(state),
      state: state?['ActiveState'] ?? 'absent',
    );
  }

  Future<Process> start({
    required List<String> command,
    required String cwd,
    Map<String, String> environment = const {},
    void Function(Process child)? onSpawn,
  }) async {
    if (recovered || _record['phase'] != 'allocated')
      throw const MomentsError('Actor process start cannot be replayed');
    if (command.isEmpty ||
        command.any((v) => v.contains('\x00')) ||
        environment.entries.any(
          (e) => !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(e.key) || e.value.contains('\x00'),
        )) {
      throw const MomentsError('Invalid actor process launch');
    }
    const inherited = [
      'PATH',
      'HOME',
      'LANG',
      'LC_ALL',
      'TMPDIR',
      'PUB_CACHE',
      'FLUTTER_ROOT',
      'ANDROID_HOME',
      'ANDROID_SDK_ROOT',
      'JAVA_HOME',
      'GRADLE_USER_HOME',
      'DISPLAY',
      'WAYLAND_DISPLAY',
      'XDG_RUNTIME_DIR',
      'DBUS_SESSION_BUS_ADDRESS',
    ];
    savePrivateState(p.join(_dir, 'process-launch.json'), {
      'version': 1,
      'owner': _record['owner'],
      'command': command,
      'cwd': p.normalize(p.absolute(cwd)),
      'environment': {
        for (final key in inherited)
          if (Platform.environment[key] case final value?) key: value,
        ...environment,
      },
    });
    _save('starting');
    try {
      final self = _worker ?? selfCommand();
      final child = await Process.start('systemd-run', [
        '--user',
        '--quiet',
        '--pipe',
        '--wait',
        '--collect',
        '--service-type=exec',
        '--unit',
        unit,
        '--description=${_description(_record)}',
        '--property=KillMode=control-group',
        '--property=Restart=no',
        '--property=TimeoutStopSec=5s',
        '--expand-environment=no',
        '--',
        ...self,
        ownedProcessWorker,
        _dir,
      ]);
      _child = child;
      var exited = false;
      _ended = child.exitCode.then((code) {
        exited = true;
        return code;
      });
      onSpawn?.call(child);
      // Let a caller cancel before granting the start permit.
      await Future<void>.delayed(Duration.zero);
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        if (_record['phase'] != 'starting') throw const MomentsError('Actor process startup was cancelled');
        if (exited) throw const MomentsError('Actor process launcher exited during startup');
        final state = _unitState(_record);
        if (state != null &&
            state['ActiveState'] == 'active' &&
            (int.tryParse(state['MainPID'] ?? '') ?? 0) > 0 &&
            _invocation.hasMatch(state['InvocationID'] ?? '')) {
          _record['invocation'] = state['InvocationID'];
          _save('running');
          return child;
        }
        if (DateTime.now().isAfter(deadline)) throw const MomentsError('Actor process activation timed out');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } on Object {
      if (_record['phase'] == 'starting') _save('attention');
      rethrow;
    }
  }

  Future<void> stop() {
    return _closing ??= () async {
      try {
        // Cancel the worker's start permit before asking the manager to stop.
        // A late queued unit cannot launch the command after this record stops.
        _save('stopping');
        final state = _unitState(_record);
        if (state != null) {
          if (_record['invocation'] == null && _invocation.hasMatch(state['InvocationID'] ?? '')) {
            _record['invocation'] = state['InvocationID'];
            _save('stopping');
          }
          final stopped = Process.runSync('systemctl', ['--user', 'stop', '--', unit]);
          if (stopped.exitCode != 0) throw const MomentsError('Actor process stop failed; ownership retained');
          final after = _unitState(_record);
          if (after != null && (_populated(after) || !const ['inactive', 'failed'].contains(after['ActiveState']))) {
            throw const MomentsError('Actor process group is still active');
          }
        }
        final child = _child;
        if (child != null) {
          await child.stdin.close().catchError((_) {});
          await _ended!.timeout(
            const Duration(seconds: 15),
            onTimeout: () => throw const MomentsError('Actor process launcher has not exited'),
          );
        }
        _save('stopped');
      } finally {
        _closing = null;
      }
    }();
  }
}

/// [worker] is the program that hosts [ownedProcessWorker]; this program by
/// default.
OwnedProcess allocateOwnedProcess(String directory, {List<String>? worker}) {
  if (!Platform.isLinux)
    throw const MomentsError('Actor process containment currently requires Linux and a user service manager');
  final dir = p.normalize(p.absolute(directory)), owner = uuidV4();
  final supervisor = processIdentity(pid);
  if (supervisor == null) throw const MomentsError('Cannot identify actor supervisor');
  final record = <String, Object?>{
    'version': 1,
    'owner': owner,
    'unit': 'mana-moments-$owner.service',
    'supervisor': identityJson(supervisor),
    'phase': 'allocated',
    'invocation': null,
  };
  createExclusive(p.join(dir, 'process.json'), utf8.encode('${jsonEncode(record)}\n'));
  syncDirectory(dir);
  return OwnedProcess._(dir, record, worker: worker);
}

OwnedProcess recoverOwnedProcess(String dir) {
  final record = _readRecord(dir);
  if (sameProcess((record['supervisor']! as Map).cast())) {
    throw const MomentsError('Actor supervisor is still alive; stop it before recovery');
  }
  return OwnedProcess._(p.normalize(p.absolute(dir)), record, recovered: true);
}

/// Read-only inspection, also used by native actors before touching the
/// device: a live launcher could otherwise install or start an app after cleanup.
({bool present, bool running, String state}) inspectOwnedProcess(String dir) =>
    OwnedProcess._(p.normalize(p.absolute(dir)), _readRecord(dir)).inspect();

/// Runs inside the already-registered user service. The command does not start
/// until its caller has pinned the unit invocation in the ownership file.
Future<int> runOwnedProcessWorker(String dir) async {
  try {
    final launch = (jsonDecode(File(p.join(dir, 'process-launch.json')).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (true) {
      final state = (jsonDecode(File(p.join(dir, 'process.json')).readAsStringSync()) as Map).cast<String, Object?>();
      if (state['owner'] != launch['owner'] ||
          !sameProcess((state['supervisor'] as Map?)?.cast()) ||
          !const ['starting', 'running'].contains(state['phase'])) {
        throw const MomentsError('Start permit unavailable');
      }
      if (state['phase'] == 'running' && state['invocation'] == Platform.environment['INVOCATION_ID']) break;
      if (DateTime.now().isAfter(deadline)) throw const MomentsError('Start permit timed out');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    final command = (launch['command']! as List).cast<String>();
    final child = await Process.start(
      command.first,
      command.skip(1).toList(),
      workingDirectory: launch['cwd']! as String,
      environment: (launch['environment']! as Map).cast<String, String>(),
      mode: ProcessStartMode.inheritStdio,
    );
    return await child.exitCode;
  } on Object {
    // Launch arguments and environment may be private; never print them on error.
    stderr.writeln('Owned actor command did not start or finish normally.');
    return 75;
  }
}
