import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'json.dart';
import 'memory.dart';

/// What the headless runtime needs from one suite worker.
abstract interface class HeadlessWorker {
  int get index;
  String get apiUrl;
  String get bridgeUrl;
  String get bridgeToken;
  List<String> get errors;
}

final class _Slot {
  int sequence = 0;
  Map<String, Object?>? pending;
  final waiters = <void Function()>{};
  final acks = <int, void Function()>{};
  bool configured = false;
  bool polling = false;
  int open = 0;
  Process? process;
  String? dead;
}

/// Headless Moments runtimes: the app under `flutter_tester` (Dart VM,
/// Flutter framework, no browser, no GPU). One `flutter test -j N` process
/// compiles the app once and runs one long-lived worker per generated entry;
/// each worker fetches its bridge envelope from this supervisor and mounts the
/// app again on every restart command (see `live_ui/headless.dart`).
final class HeadlessRuntime {
  HeadlessRuntime._(this._server, this._slots, this._workers, this._directory, this._output, this._log);

  final HttpServer _server;
  final List<_Slot> _slots;
  final List<HeadlessWorker> _workers;
  final String _directory;
  final IOSink _output;
  final void Function(String text) _log;
  final _processes = <Process>{};
  late List<String> _files;
  late Map<String, String> _defines;
  late String _project, _tmp, _control, _run;
  double startupMs = 0;

  static Future<HeadlessRuntime> start({
    required String project,
    required String run,
    required List<HeadlessWorker> workers,
    required ({String file, String function}) entry,
    required Map<String, String> defines,
    void Function(String text)? log,
    Duration startupTimeout = const Duration(seconds: 240),
    bool releaseCompiler = true,
  }) async {
    final slots = [for (final _ in workers) _Slot()];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final directory = p.join(project, 'moments/.headless');
    final runtime = HeadlessRuntime._(
      server,
      slots,
      workers,
      directory,
      File(p.join(run, 'flutter-test.log')).openWrite(),
      log ?? (_) {},
    );
    server.listen(runtime._handle);
    runtime
      .._project = project
      .._run = run
      .._control = 'http://127.0.0.1:${server.port}'
      .._defines = defines
      .._tmp = p.join(directory, 'tmp');
    if (Directory(directory).existsSync()) Directory(directory).deleteSync(recursive: true);
    Directory(runtime._tmp).createSync(recursive: true);
    final target = p.relative(p.join(project, entry.file), from: directory);
    runtime._files = [
      for (final worker in workers)
        () {
          final file = p.join(directory, 'w${worker.index}_test.dart');
          File(file).writeAsStringSync("import '$target';\n\nvoid main() => ${entry.function}(${worker.index});\n");
          return p.relative(file, from: project);
        }(),
    ];
    final started = nowMs();
    final all = [for (final worker in workers) worker.index];
    await runtime._spawn(all);
    await runtime._ready(all, startupTimeout);
    runtime._log('headless workers ready in ${(nowMs() - started).round()} ms');
    if (releaseCompiler) {
      for (final child in runtime._processes) {
        runtime._stopCompiler(child.pid);
      }
    }
    runtime.startupMs = nowMs() - started;
    return runtime;
  }

  Future<void> _reply(HttpResponse response, int code, [Object? body]) async {
    response
      ..statusCode = code
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store');
    if (code != 204) response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      final match = RegExp(r'^/w/(\d+)(/runtime)?$').firstMatch(request.uri.path);
      final index = int.tryParse(match?[1] ?? '');
      if (match == null || index == null || index >= _workers.length) {
        await _reply(response, 404, {'error': 'Unknown worker'});
        return;
      }
      final worker = _workers[index], slot = _slots[index];
      if (match[2] != null) {
        slot.configured = true;
        {
          await _reply(response, 200, {
            'version': 1,
            'apiUrl': worker.apiUrl,
            'bridgeUrl': worker.bridgeUrl,
            'bridgeToken': worker.bridgeToken,
          });
          return;
        }
      }
      if (request.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final ack = body['ack'];
        slot.acks.remove(ack)?.call();
        {
          await _reply(response, 200, {'received': true});
          return;
        }
      }
      slot
        ..polling = true
        ..open += 1;
      var closed = false;
      void finish() {
        if (closed) return;
        closed = true;
        slot.open -= 1;
      }

      final after = int.tryParse(request.uri.queryParameters['after'] ?? '0') ?? 0;
      final pending = slot.pending;
      if (pending != null && (pending['sequence']! as int) > after) {
        finish();
        {
          await _reply(response, 200, pending);
          return;
        }
      }
      final done = Completer<void>();
      void waiter() {
        if (!done.isCompleted) done.complete();
      }

      slot.waiters.add(waiter);
      final timer = Timer(const Duration(seconds: 15), waiter);
      unawaited(response.done.then((_) => waiter(), onError: (_) => waiter()));
      await done.future;
      timer.cancel();
      slot.waiters.remove(waiter);
      final next = slot.pending;
      finish();
      if (next != null && (next['sequence']! as int) > after) {
        await _reply(response, 200, next);
      } else {
        await _reply(response, 204);
      }
    } on Object catch (error) {
      try {
        await _reply(response, 400, {'error': '$error'});
      } on Object {
        // The client went away.
      }
    }
  }

  // An uncaught exception ends that worker's test; the exception text is the
  // block flutter_test printed just before marking the entry failed.
  Future<void> _spawn(List<int> indices) async {
    final child = await Process.start(
      'flutter',
      [
        'test',
        for (final i in indices) _files[i],
        '-j',
        '${indices.length}',
        '-r',
        'expanded',
        '--no-pub',
        for (final MapEntry(:key, :value) in _defines.entries) '--dart-define=$key=$value',
      ],
      workingDirectory: _project,
      environment: {'TMPDIR': _tmp, 'MOMENTS_CONTROL_URL': _control},
    );
    _processes.add(child);
    unawaited(
      child.exitCode.then((_) {
        _processes.remove(child);
        for (final i in indices) {
          if (_slots[i].process == child) _slots[i].dead ??= 'flutter test exited';
        }
      }),
    );
    var pending = '';
    var block = <String>[];
    void read(String chunk) {
      _output.write(chunk);
      pending += chunk;
      final lines = pending.split('\n');
      pending = lines.removeLast();
      for (final line in lines) {
        if (line.startsWith('══╡ EXCEPTION')) {
          block = [line];
        } else if (block.isNotEmpty && block.length < 40) {
          block.add(line);
        }
        final failed = RegExp(r'w(\d+)_test\.dart: moments headless runtime \[E\]').firstMatch(line);
        final index = int.tryParse(failed?[1] ?? '');
        if (index != null && indices.contains(index)) {
          final text = block.skip(1).take(3).join(' ').trim();
          final reason = text.isEmpty ? 'worker test failed' : text;
          _slots[index].dead = reason;
          _workers[index].errors.add('uncaught: $reason');
          _log('worker $index died: $reason');
          block = [];
        }
      }
    }

    child.stdout.transform(utf8.decoder).listen(read);
    child.stderr.transform(utf8.decoder).listen(read);
    for (final i in indices) {
      _slots[i]
        ..process = child
        ..dead = null
        ..configured = false
        ..polling = false;
    }
  }

  Future<void> _ready(List<int> indices, Duration timeout) async {
    final started = nowMs();
    while (!indices.every((i) => _slots[i].configured && _slots[i].polling)) {
      final dead = indices.where((i) => _slots[i].dead != null).firstOrNull;
      if (dead != null) {
        throw MomentsError('Headless worker $dead failed during startup; inspect ${p.join(_run, 'flutter-test.log')}');
      }
      if (nowMs() - started > timeout.inMilliseconds) throw const MomentsError('Headless workers did not start');
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  int _send(int index, String operation) {
    final slot = _slots[index];
    slot.pending = {'operation': operation, 'sequence': ++slot.sequence};
    for (final waiter in [...slot.waiters]) {
      waiter();
    }
    slot.waiters.clear();
    return slot.sequence;
  }

  Future<void> restart(HeadlessWorker worker, {Duration timeout = const Duration(seconds: 30)}) async {
    final slot = _slots[worker.index];
    // A live worker keeps a long poll open (it reopens one at once after each
    // reply); none for a few seconds means its runtime is gone.
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (slot.dead == null && slot.open == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (slot.dead == null && slot.open == 0) slot.dead = 'worker stopped polling (runtime exited)';
    if (slot.dead != null) {
      _log('respawning worker ${worker.index}');
      _log('worker ${worker.index}: ${slot.dead}');
      slot
        ..sequence = 0
        ..pending = null
        ..open = 0;
      slot.acks.clear();
      await _spawn([worker.index]);
      await _ready([worker.index], const Duration(seconds: 120));
    }
    final acknowledged = Completer<void>();
    slot.acks[slot.sequence + 1] = () {
      if (!acknowledged.isCompleted) acknowledged.complete();
    };
    _send(worker.index, 'restart');
    await acknowledged.future.timeout(
      timeout,
      onTimeout: () => throw const MomentsError('Headless worker did not remount the app'),
    );
  }

  int memory() => _processes.fold(0, (sum, child) => sum + treeMemory(child.pid));

  Future<void> close() async {
    for (final worker in _workers) {
      _send(worker.index, 'stop');
    }
    await Future.wait([
      for (final child in [..._processes])
        child.exitCode.timeout(
          const Duration(seconds: 10),
          onTimeout: () {
            child.kill(ProcessSignal.sigterm);
            return child.exitCode;
          },
        ),
    ]);
    await _output.close();
    await _server.close(force: true);
    if (Directory(_directory).existsSync()) Directory(_directory).deleteSync(recursive: true);
  }

  // Every worker entry is compiled before it starts; afterwards flutter test
  // only keeps its incremental compiler around. Stopping that descendant
  // (never a process matched by name system-wide) returns its memory to the run.
  void _stopCompiler(int root) {
    for (final pid in descendants(root)) {
      String command;
      try {
        command = File('/proc/$pid/cmdline').readAsStringSync();
      } on Object {
        continue;
      }
      if (command.contains('frontend_server') && Process.killPid(pid)) _log('released idle compiler $pid');
    }
  }
}
