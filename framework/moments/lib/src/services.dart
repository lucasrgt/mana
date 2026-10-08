import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'errors.dart';
import 'watch.dart' show WatchedBackend;

Future<void> assertFreePort(int port) async {
  final ServerSocket server;
  try {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
  } on SocketException {
    throw MomentsError('Port $port is already in use');
  }
  await server.close();
}

Future<bool> isFreePort(int port) async {
  try {
    await assertFreePort(port);
    return true;
  } on MomentsError {
    return false;
  }
}

/// The digest of [paths] (files or trees) under [root], byte-compatible with
/// the JS runner: `JSON.stringify([[path, base64 | null], ...])`.
String sourceFingerprint(String root, List<String> paths) {
  final entries = <List<Object?>>[];
  void visit(String path) {
    final type = FileSystemEntity.typeSync(path);
    final relative = path == root ? '' : p.relative(path, from: root);
    if (type == FileSystemEntityType.notFound) {
      entries.add([relative, null]);
    } else if (type == FileSystemEntityType.directory) {
      final names = [for (final entry in Directory(path).listSync()) p.basename(entry.path)]..sort();
      for (final name in names) {
        visit(p.join(path, name));
      }
    } else {
      entries.add([relative, base64Encode(File(path).readAsBytesSync())]);
    }
  }

  for (final path in paths) {
    visit(p.normalize(p.join(root, path)));
  }
  return hashText(jsonEncode(entries));
}

/// Child services get explicit settings, not the launcher shell's deployment
/// credentials, database URLs, proxies or cloud SDK configuration.
Map<String, String> serviceEnvironment({
  required String directory,
  Map<String, String> environment = const {},
  Map<String, String> ownership = const {},
  Map<String, String>? inherited,
}) {
  _validateEnvironment(environment);
  return {
    'PATH': (inherited ?? Platform.environment)['PATH'] ?? '',
    'LANG': 'C.UTF-8',
    ...environment,
    'HOME': directory,
    'TMPDIR': p.join(directory, 'tmp'),
    ...ownership,
  };
}

void _validateEnvironment(Map<String, String> environment) {
  for (final MapEntry(:key, :value) in environment.entries) {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key) || value.contains('\x00')) {
      throw const MomentsError('Service environment must contain named string values');
    }
    if (key == 'HOME' || key == 'TMPDIR' || key.startsWith('MANA_RESOURCE_')) {
      throw MomentsError(
        'Service environment cannot override $key; the supervisor owns isolation and resource identity',
      );
    }
  }
}

/// One app-owned backend process the launcher keeps current: how to prepare,
/// compile and serve it, which sources it watches and how to know it is ready.
/// Where services record their processes and the ownership labels they carry.
abstract interface class ServiceLifecycle {
  void track(Process child, String role);
  Map<String, String> environment();
}

final class ServiceDefinition {
  const ServiceDefinition({
    required this.name,
    required this.cwd,
    required this.port,
    required this.ready,
    required this.serve,
    this.prepare,
    this.compile,
    this.prepareIdempotent = false,
    this.watch = const [],
    this.environment = const {},
    this.timeout,
    this.commandTimeout,
  });

  final String name;
  final String cwd;
  final int port;
  final Future<bool> Function() ready;
  final List<String> serve;
  final List<String>? prepare;
  final List<String>? compile;
  final bool prepareIdempotent;
  final List<String> watch;
  final Map<String, String> environment;
  final Duration? timeout;
  final Duration? commandTimeout;
}

void validateServices(List<ServiceDefinition> definitions) {
  final names = <String>{}, ports = <int>{};
  for (final d in definitions) {
    if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(d.name) || !names.add(d.name))
      throw const MomentsError('Invalid or duplicate service name');
    if (d.port < 1 || d.port > 65535 || !ports.add(d.port))
      throw MomentsError('Invalid or duplicate port for service ${d.name}');
    if (d.cwd.trim().isEmpty) throw MomentsError('Service ${d.name} needs cwd');
    for (final (key, command) in [('prepare', d.prepare), ('compile', d.compile), ('serve', d.serve)]) {
      if (command == null && key != 'serve') continue;
      if (command == null || command.isEmpty || command.any((v) => v.isEmpty || v.contains('\x00'))) {
        throw MomentsError('Service ${d.name} needs a $key argv array');
      }
    }
    if (d.watch.any((v) => v.isEmpty)) throw MomentsError('Service ${d.name} watch must contain paths');
    _validateEnvironment(d.environment);
  }
}

final class _Service {
  _Service(this.definition);
  final ServiceDefinition definition;
  String phase = 'stopped';
  Process? child;
  bool exited = false;
  String? applied, generation, error;
}

/// App-owned adapters declare commands and readiness. No framework knowledge
/// of Phoenix, credentials, application tables or fixture recipes is needed.
final class Services implements WatchedBackend {
  Services({
    required List<ServiceDefinition> definitions,
    required this.directory,
    void Function(String text)? log,
    void Function()? onFailure,
    this.lifecycle,
    this.prepareOnStart = true,
  }) : _log = log ?? print,
       _onFailure = onFailure ?? (() {}) {
    validateServices(definitions);
    _services = [for (final d in definitions) _Service(d)];
  }

  final String directory;
  final void Function(String text) _log;
  final void Function() _onFailure;
  final ServiceLifecycle? lifecycle;
  final bool prepareOnStart;
  late final List<_Service> _services;
  final _children = <Process, Future<int>>{};
  var _closed = false, _busy = false;

  List<Map<String, Object?>> status() => [
    for (final service in _services)
      () {
        final current = sourceFingerprint(service.definition.cwd, service.definition.watch);
        final running = !_closed && service.child != null && !service.exited;
        return <String, Object?>{
          'name': service.definition.name,
          'phase': service.phase,
          'error': service.error,
          'running': running,
          'generation': service.generation,
          'source': {'current': current, 'applied': service.applied},
          'codeChanged': current != service.applied,
        };
      }(),
  ];

  @override
  String fingerprint() => _services.map((s) => sourceFingerprint(s.definition.cwd, s.definition.watch)).join(':');

  Future<void> _stopChild(Process? child) async {
    if (child == null) return;
    final exit = _children[child];
    if (exit == null) return;
    child.kill(ProcessSignal.sigterm);
    await exit.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        child.kill(ProcessSignal.sigkill);
        return exit;
      },
    );
  }

  Future<Process> _launch(_Service service, List<String> command) async {
    if (_closed) throw const MomentsError('Services stopped');
    final home = p.join(directory, 'services', service.definition.name);
    Directory(p.join(home, 'tmp')).createSync(recursive: true);
    Process.runSync('chmod', ['700', p.join(home, 'tmp')]);
    final environment = serviceEnvironment(
      directory: home,
      environment: service.definition.environment,
      ownership: lifecycle?.environment() ?? const {},
    );
    final log = File(p.join(directory, '${service.definition.name}.log')).openWrite(mode: FileMode.append);
    final Process child;
    try {
      child = await Process.start(
        command.first,
        command.skip(1).toList(),
        workingDirectory: service.definition.cwd,
        environment: environment,
        includeParentEnvironment: false,
      );
    } on ProcessException {
      await log.close();
      service.error = 'Cannot start ${service.definition.name}; inspect ${service.definition.name}.log';
      rethrow;
    }
    lifecycle?.track(child, 'service-${service.definition.name}');
    // Both streams write to one log; piping one would bind the sink and make
    // the other's first write throw.
    final done = Future.wait([child.stdout.forEach(log.add), child.stderr.forEach(log.add)])
        .catchError((_) => <void>[])
        .whenComplete(() => log.close().catchError((_) {}));
    final exit = child.exitCode.then((code) async {
      await done.catchError((_) => <void>[]);
      _children.remove(child);
      if (service.child == child) service.exited = true;
      return code;
    });
    _children[child] = exit;
    service
      ..child = child
      ..exited = false;
    return child;
  }

  Future<void> _runCommand(_Service service, List<String> command) async {
    final child = await _launch(service, command);
    final timeout = service.definition.commandTimeout ?? const Duration(seconds: 60);
    final code = await _children[child]!.timeout(
      timeout,
      onTimeout: () async {
        await _stopChild(child);
        throw MomentsError('${service.definition.name} command timed out; inspect ${service.definition.name}.log');
      },
    );
    if (code != 0)
      throw MomentsError('${service.definition.name} command failed; inspect ${service.definition.name}.log');
    if (_closed) throw const MomentsError('Services stopped');
  }

  Future<void> _ready(_Service service, Process child) async {
    final deadline = DateTime.now().add(service.definition.timeout ?? const Duration(seconds: 60));
    while (!_closed && DateTime.now().isBefore(deadline)) {
      if (!_children.containsKey(child) || service.error != null) break;
      try {
        if (await service.definition.ready() && _children.containsKey(child)) return;
      } on Object {
        // Not ready yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw MomentsError('${service.definition.name} did not become ready; inspect ${service.definition.name}.log');
  }

  @override
  Future<void> ensure() async {
    if (_closed) throw const MomentsError('Services stopped');
    if (_busy) throw const MomentsError('Service update already running');
    _busy = true;
    try {
      for (final service in _services) {
        final definition = service.definition;
        final next = sourceFingerprint(definition.cwd, definition.watch);
        if (service.phase == 'ready' && service.applied == next) continue;
        final previous = service.child;
        final initial = service.applied == null;
        service
          ..phase = initial ? 'starting' : 'updating'
          ..error = null;
        try {
          if (initial) await assertFreePort(definition.port);
          _log('Moments: ${initial ? 'starting' : 'updating'} ${definition.name}');
          // A failed compile leaves the previous server alive; it is never
          // reported as the current revision and can recover after the next edit.
          final command = initial && prepareOnStart ? definition.prepare : definition.compile;
          if (command != null) await _runCommand(service, command);
          await _stopChild(previous);
          if (_closed) throw const MomentsError('Services stopped');
          final child = await _launch(service, definition.serve);
          unawaited(
            _children[child]!.then((_) {
              if (!_closed && service.child == child && service.phase == 'ready') {
                service
                  ..phase = 'error'
                  ..error = '${definition.name} exited; inspect ${definition.name}.log';
                _onFailure();
              }
            }),
          );
          await _ready(service, child);
          service
            ..applied = next
            ..generation = uuidV4()
            ..phase = 'ready'
            ..error = null;
        } on Object catch (error) {
          final failed = service.child;
          if (failed != previous) await _stopChild(failed);
          service
            ..child = previous
            ..phase = 'error'
            ..error = error is MomentsError ? error.message : '$error';
          rethrow;
        }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> preflight() async {
    for (final service in _services) {
      await assertFreePort(service.definition.port);
    }
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait([
      for (final child in [..._children.keys]) _stopChild(child),
    ]);
    for (final service in _services) {
      service
        ..phase = 'stopped'
        ..generation = null;
    }
  }
}
