import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show assertOwned, findOwnedDatabase;
import 'package:path/path.dart' as p;

import 'android_transport.dart';
import 'errors.dart';
import 'json.dart';
import 'lifecycle.dart';
import 'services.dart';

Map<String, Object?> _read(String path) => (jsonDecode(File(path).readAsStringSync()) as Map).cast();
Future<void> _pause() => Future<void>.delayed(const Duration(milliseconds: 100));

String _docker(List<String> args) {
  final result = Process.runSync('docker', args);
  if (result.exitCode != 0)
    throw const MomentsError('Owned container operation failed; recovery evidence was preserved');
  return (result.stdout as String).trim();
}

bool _containerExists(String id) =>
    _docker(['ps', '-aq', '--no-trunc', '--filter', 'id=$id']).split(RegExp(r'\s+')).contains(id);

List<Map<String, Object?>> ownedContainers(Map<String, Object?> state) {
  final ids = _docker([
    'ps',
    '-aq',
    '--no-trunc',
    '--filter',
    'label=dev.moments.owner=${state['instanceId']}',
    '--filter',
    'label=dev.moments.run=${state['runId']}',
  ]).split(RegExp(r'\s+')).where((id) => id.isNotEmpty);
  return [
    for (final id in ids)
      ...() {
        final Map<String, Object?> container;
        try {
          container = ((jsonDecode(_docker(['inspect', id])) as List).single as Map).cast();
        } on MomentsError {
          if (!_containerExists(id)) return const <Map<String, Object?>>[];
          rethrow;
        }
        final labels = ((container['Config'] as Map?)?['Labels'] as Map?) ?? const {};
        if (labels['dev.moments.owner'] != state['instanceId'] ||
            labels['dev.moments.run'] != state['runId'] ||
            labels['dev.moments.workspace'] != state['workspace'] ||
            labels['dev.moments.role'] != 'service') {
          throw const MomentsError('Container ownership does not match this execution');
        }
        return [container];
      }(),
  ];
}

bool _running(Map<String, Object?> container) => (container['State'] as Map?)?['Running'] == true;

Future<void> stopOwnedResources(
  Map<String, Object?> state, {
  bool stopDatabase = true,
  Map<String, Object?>? instance,
  String? directory,
}) async {
  String? androidDirectory;
  final android = state['android'] as Map?;
  if (android != null) {
    if (state['version'] != 3 || directory == null)
      throw const MomentsError('Android recovery needs its owning lifecycle directory');
    androidDirectory = p.join(directory, 'android-${state['runId']}');
    final file = p.join(androidDirectory, 'transport.json');
    if (File(file).existsSync()) {
      final transport = _read(file);
      if (transport['owner'] != state['runId'] ||
          transport['device'] != android['device'] ||
          !jsonEqual([
            for (final x in (transport['ports'] as List? ?? const [])) (x as Map)['port'],
          ], android['ports'])) {
        throw const MomentsError('Android journal differs from lifecycle ownership');
      }
    }
  }
  // Validate every known container before sending a signal to any process.
  if (state['databaseStarted'] == true && instance == null) {
    throw const MomentsError(
      'Database preparation has no committed instance metadata; ownership retained for inspection',
    );
  }
  final containers = ownedContainers(state);
  Map<String, Object?>? database;
  if (instance != null) {
    if (instance['id'] != state['instanceId'] ||
        (instance['workspace'] != null && instance['workspace'] != state['workspace'])) {
      throw const MomentsError('Database identity changed');
    }
    database = findOwnedDatabase(instance, allowAbsent: instance['databasePhase'] == 'creating');
  }
  final records = [
    for (final record in (state['processes']! as List).cast<Map>())
      if (record['pid'] != pid) record.cast<String, Object?>(),
  ];
  for (final record in records.reversed) {
    signalOwnedProcess(record, ProcessSignal.sigterm);
  }
  var deadline = DateTime.now().add(const Duration(seconds: 5));
  while (records.any(sameProcess) && DateTime.now().isBefore(deadline)) {
    await _pause();
  }
  for (final record in records) {
    signalOwnedProcess(record, ProcessSignal.sigkill);
  }
  deadline = DateTime.now().add(const Duration(seconds: 2));
  while (records.any(sameProcess) && DateTime.now().isBefore(deadline)) {
    await _pause();
  }
  if (records.any(sameProcess))
    throw const MomentsError('An owned process is still running; ownership record retained');
  if (androidDirectory != null && File(p.join(androidDirectory, 'transport.json')).existsSync()) {
    await recoverAndroidTransport(androidDirectory);
  }
  for (final container in containers) {
    final id = container['Id']! as String;
    if (_running(container) && _containerExists(id)) {
      try {
        _docker(['stop', '--time', '5', id]);
      } on MomentsError {
        if (_containerExists(id)) rethrow;
      }
    }
  }
  if (ownedContainers(state).any(_running)) throw const MomentsError('An owned container is still running');
  if (stopDatabase && database != null && state['databaseStarted'] == true) {
    _docker(['stop', '--time', '5', database['Id']! as String]);
    if (_running(assertOwned(instance!))) throw const MomentsError('Database did not stop');
  }
  for (final port in (state['ports']! as List).cast<int>()) {
    if (!await isFreePort(port)) {
      throw MomentsError(
        'Port $port is occupied by an unconfirmed process; it was not signaled and ownership was retained',
      );
    }
  }
}

Future<Map<String, Object?>> downInstance(String project, {Duration timeout = const Duration(seconds: 25)}) async {
  if (!Directory(p.join(project, 'moments')).existsSync())
    throw const MomentsError('No Moments project at this location');
  final directory = p.join(project, 'moments', '.backend');
  Directory(directory).createSync(recursive: true);
  return withInstanceLock(directory, () async {
    assertNoManagedSession(directory);
    final lock = p.join(directory, 'running.json'), manifest = p.join(directory, 'instance.json');
    if (!File(lock).existsSync()) {
      if (File(manifest).existsSync()) {
        final instance = _read(manifest);
        final database = findOwnedDatabase(instance, allowAbsent: instance['databasePhase'] == 'creating');
        if (database != null && _running(database)) {
          throw const MomentsError('Database is active without execution ownership; inspect its original launcher');
        }
      }
      return {'status': 'stopped', 'preserved': true, 'mode': 'already-stopped'};
    }
    final state = validateLifecycle(_read(lock), project);
    final instance = File(manifest).existsSync() ? _read(manifest) : null;
    var mode = 'recovered';
    final supervisor = (state['supervisor']! as Map).cast<String, Object?>();
    if (sameProcess(supervisor)) {
      mode = 'graceful';
      final runtimeFile = p.join(directory, '.runtime.json');
      if (!File(runtimeFile).existsSync())
        throw const MomentsError('Supervisor is still starting; wait for readiness before moments down');
      final runtime = _read(runtimeFile);
      final url = Uri.parse(runtime['url']! as String);
      if (runtime['pid'] != supervisor['pid'] ||
          url.scheme != 'http' ||
          url.host != '127.0.0.1' ||
          !(state['ports']! as List).contains(url.port)) {
        throw const MomentsError('Runtime address or process does not match execution ownership');
      }
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      try {
        final request = await client.postUrl(url.resolve('/dev/stop'));
        request.headers
          ..set('Authorization', 'Bearer ${runtime['token']}')
          ..set('Content-Type', 'application/json');
        request.add(utf8.encode(jsonEncode({'preserve': true})));
        final response = await request.close().timeout(const Duration(seconds: 3));
        await response.drain<void>();
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const MomentsError('Supervisor refused stop; no resources were signaled');
        }
      } finally {
        client.close(force: true);
      }
      final deadline = DateTime.now().add(timeout);
      while (sameProcess(supervisor) && DateTime.now().isBefore(deadline)) {
        await _pause();
      }
      if (sameProcess(supervisor))
        throw const MomentsError('Supervisor is still running; do not remove its ownership record');
    }
    // An ended supervisor may have recorded more descendants before it exited.
    final latest = File(lock).existsSync() ? validateLifecycle(_read(lock), project) : state;
    if (latest['runId'] != state['runId'] || sameProcess((latest['supervisor']! as Map).cast())) {
      throw const MomentsError('Execution changed during stop');
    }
    await stopOwnedResources(latest, instance: instance, directory: directory);
    clearFlutterTemporaryFiles(directory, latest['runId']! as String);
    for (final name in ['.runtime.json', '.defines.json', 'running.json']) {
      final file = File(p.join(directory, name));
      if (file.existsSync()) file.deleteSync();
    }
    return {'status': 'stopped', 'preserved': true, 'mode': mode, 'runId': state['runId']};
  });
}
