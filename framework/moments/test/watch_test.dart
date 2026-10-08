import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/errors.dart';
import 'package:moments/src/flutter_machine.dart';
import 'package:moments/src/flutter_target.dart';
import 'package:moments/src/watch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Future<void> eventually(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(predicate(), isTrue, reason: 'Expected state within deadline');
}

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

final class Machine implements WatchedMachine {
  Machine({required this.restartWith, this.isReady});
  final Future<Object?> Function(bool fullRestart) restartWith;
  final bool Function()? isReady;
  @override
  bool ready() => isReady?.call() ?? true;
  @override
  Future<Object?> restart({bool fullRestart = true}) => restartWith(fullRestart);
}

/// Absent JS methods keep the JS defaults: claimed, observed, no reload.
final class Runtime implements WatchedMoments {
  Runtime({
    this.prepare,
    this.restoration,
    this.marked,
    this.claim,
    this.observed,
    this.reload,
    this.frame,
    this.frameAfterId,
    this.cancel,
    this.blocker,
    Map<String, Object?>? checkpoint,
  }) : _checkpoint = checkpoint ?? const {};
  final Future<void Function()> Function()? prepare;
  final Map<String, Object?>? Function()? restoration;
  final void Function()? marked;
  final bool Function()? claim, observed, reload;
  final String Function()? frame;
  final Map<String, Object?>? Function(String id)? frameAfterId;
  final void Function(String id)? cancel;
  final Map<String, Object?>? Function(Map<String, Object?> checkpoint, bool fullRestart)? blocker;
  final Map<String, Object?> _checkpoint;

  @override
  String sourceFingerprint() => throw const MomentsError('No source inventory');
  @override
  bool hasRuntimeClaim() => claim?.call() ?? true;
  @override
  bool hasObservedRuntime() => observed?.call() ?? true;
  @override
  bool canReload() => reload?.call() ?? false;
  @override
  Map<String, Object?> checkpoint() => _checkpoint;
  @override
  Future<void Function()> prepareRestart() => prepare != null ? prepare!() : Future.value(() {});
  @override
  String requestFrame(Map<String, Object?> checkpoint) => frame!();
  @override
  void cancelFrame(String id) => cancel?.call(id);
  @override
  Map<String, Object?>? blockerAfter(Map<String, Object?> checkpoint, {bool fullRestart = false, String? frameId}) =>
      blocker?.call(checkpoint, fullRestart);
  @override
  Map<String, Object?>? restorationAfter(Map<String, Object?> checkpoint) => restoration?.call();
  @override
  Map<String, Object?>? frameAfter(String id) => frameAfterId?.call(id);
  @override
  void markCodeApplied(Map<String, Object?> checkpoint) => marked?.call();
}

final class Backend implements WatchedBackend {
  Backend(this.source, this.ensureWith);
  final String Function() source;
  final Future<void> Function() ensureWith;
  @override
  String fingerprint() => source();
  @override
  Future<void> ensure() => ensureWith();
}

/// A `flutter run --machine` process driven by the test.
final class Child implements Process {
  final _out = StreamController<List<int>>();
  final _in = StreamController<List<int>>.broadcast();
  final _exit = Completer<int>();
  late final IOSink _sink = IOSink(_in.sink);

  void write(String text) => _out.add(utf8.encode(text));
  Stream<Map<String, Object?>> get commands =>
      _in.stream.map((bytes) => ((jsonDecode(utf8.decode(bytes)) as List).first as Map).cast<String, Object?>());
  void exit(int code) => _exit.complete(code);

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => _sink;
  @override
  int get pid => 1;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

String project(String prefix) {
  final dir = temporary(prefix);
  File(p.join(dir, 'view.dart')).writeAsStringSync('one');
  return dir;
}

MomentWatcher watch(
  String project, {
  List<String> paths = const ['view.dart'],
  required WatchedMachine machine,
  required WatchedMoments moments,
  WatchedBackend? backend,
  bool enabled = true,
  int interval = 5,
  int debounce = 350,
  int restoreTimeout = 15000,
  bool Function()? automaticAllowed,
}) {
  final watcher = MomentWatcher(
    project: project,
    paths: paths,
    machine: machine,
    moments: moments,
    backend: backend,
    enabled: enabled,
    interval: Duration(milliseconds: interval),
    debounce: Duration(milliseconds: debounce),
    restoreTimeout: Duration(milliseconds: restoreTimeout),
    automaticAllowed: automaticAllowed,
    log: (_) {},
  );
  addTearDown(watcher.close);
  return watcher;
}

void main() {
  test('machine protocol handles chunked output, failed compilation and process exit', () async {
    final child = Child(), commands = <Map<String, Object?>>[];
    child.commands.listen(commands.add);
    final machine = FlutterMachine(child, log: (_) {}, timeout: const Duration(seconds: 1));
    try {
      child.write('Build output\n[{"event":"app.start","params":{"appId":"app"}}]\n[{"event":"app.st');
      await sleep(5);
      expect(machine.ready(), isFalse);
      child.write('arted","params":{"appId":"app"}}]\n');
      await sleep(5);
      expect(machine.ready(), isTrue);
      final failed = machine.restart();
      await sleep(5);
      expect(commands[0]['method'], 'app.restart');
      expect((commands[0]['params']! as Map)['fullRestart'], true);
      child.write(
        '${jsonEncode([
          {
            'id': commands[0]['id'],
            'result': {'code': 1, 'message': 'Invalid Dart'},
          },
        ])}\n',
      );
      await expectLater(failed, throwsA(predicate((e) => '$e'.contains('Invalid Dart'))));
      final retried = machine.restart();
      await sleep(5);
      child.write(
        '${jsonEncode([
          {
            'id': commands[1]['id'],
            'result': {'code': 0},
          },
        ])}\n',
      );
      await retried;
      final interrupted = machine.restart();
      child.exit(1);
      await expectLater(interrupted, throwsA(predicate((e) => '$e'.contains('exited'))));
      expect(machine.ready(), isFalse);
    } finally {
      machine.close();
    }
  });

  test('watcher coalesces atomic saves, queues edits during compilation and waits for restoration', () async {
    final dir = project('moment-watch-');
    var runs = 0, restored = false, marked = 0;
    Completer<void>? finish;
    final watcher = watch(
      dir,
      debounce: 25,
      restoreTimeout: 500,
      machine: Machine(
        restartWith: (_) {
          runs++;
          restored = false;
          finish = Completer<void>();
          return finish!.future;
        },
      ),
      moments: Runtime(restoration: () => restored ? {'name': 'checkout'} : null, marked: () => marked++),
    );
    File(p.join(dir, 'view.tmp')).writeAsStringSync('two');
    File(p.join(dir, 'view.tmp')).renameSync(p.join(dir, 'view.dart'));
    File(p.join(dir, 'view.dart')).writeAsStringSync('three');
    await eventually(() => runs == 1);
    File(p.join(dir, 'view.dart')).writeAsStringSync('four');
    await sleep(50);
    expect(runs, 1, reason: 'No concurrent restart');
    finish!.complete();
    await eventually(() => watcher.status()['phase'] == 'restoring');
    expect(marked, 0, reason: 'Compilation alone is not proof of restoration');
    restored = true;
    await eventually(() => runs == 2);
    restored = true;
    finish!.complete();
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(marked, 2);
    expect(runs, 2);
    expect(watcher.status()['totalMs'] as num, greaterThanOrEqualTo(0));
    File(p.join(dir, 'unwatched.dart')).writeAsStringSync('unrelated');
    await sleep(50);
    expect(runs, 2);
  });

  test('failed compilation is reported once; correction retries and stopping cancels the watcher', () async {
    final dir = project('moment-watch-error-');
    File(p.join(dir, 'view.dart')).writeAsStringSync('valid');
    var runs = 0;
    final watcher = watch(
      dir,
      debounce: 10,
      machine: Machine(
        restartWith: (_) async {
          if (++runs == 1) throw const MomentsError('Dart syntax error');
          return null;
        },
      ),
      moments: Runtime(restoration: () => {'name': 'checkout'}),
    );
    File(p.join(dir, 'view.dart')).writeAsStringSync('invalid');
    await eventually(() => watcher.status()['phase'] == 'error');
    await sleep(75);
    expect(runs, 1);
    expect(watcher.status()['error'], contains('syntax'));
    File(p.join(dir, 'view.dart')).writeAsStringSync('fixed');
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(runs, 2);
    watcher.close();
    File(p.join(dir, 'view.dart')).writeAsStringSync('later');
    await sleep(50);
    expect(runs, 2);
  });

  test('disabled watching still allows explicit refresh and missing runtime never reports ready', () async {
    final dir = project('moment-watch-manual-');
    var runs = 0, marked = false;
    final watcher = watch(
      dir,
      enabled: false,
      restoreTimeout: 20,
      machine: Machine(restartWith: (_) async => runs++),
      moments: Runtime(restoration: () => null, marked: () => marked = true),
    );
    File(p.join(dir, 'view.dart')).writeAsStringSync('two');
    await sleep(50);
    expect(runs, 0);
    final result = await watcher.refresh();
    expect(result['phase'], 'error');
    expect(marked, isFalse);
    expect(result['error'], contains('no new Flutter runtime'));
  });

  test('a timed out Flutter operation cannot overlap a subsequent restart', () async {
    final child = Child();
    final machine = FlutterMachine(child, log: (_) {}, timeout: const Duration(milliseconds: 15));
    try {
      child.write(
        '[{"event":"app.start","params":{"appId":"app"}},{"event":"app.started","params":{"appId":"app"}}]\n',
      );
      await sleep(5);
      await expectLater(machine.restart(), throwsA(predicate((e) => '$e'.contains('timed out'))));
      expect(machine.ready(), isFalse);
      await expectLater(machine.restart(), throwsA(predicate((e) => '$e'.contains('not ready'))));
    } finally {
      machine.close();
    }
  });

  test('preparing domain data pauses automatic and manual refresh without losing source changes', () async {
    final dir = project('moment-watch-held-');
    var runs = 0;
    final watcher = watch(
      dir,
      debounce: 10,
      machine: Machine(restartWith: (_) async => runs++),
      moments: Runtime(restoration: () => {'name': 'checkout'}),
    );
    final release = watcher.pause();
    File(p.join(dir, 'view.dart')).writeAsStringSync('two');
    await eventually(() => watcher.status()['pending'] == true);
    await expectLater(watcher.refresh(), throwsA(predicate((e) => '$e'.contains('preparation'))));
    expect(watcher.pause, throwsA(predicate((e) => '$e'.contains('another operation'))));
    await sleep(40);
    expect(runs, 0);
    release();
    release();
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(runs, 1);
    expect(watcher.status()['held'], isFalse);
  });

  test('manual refresh consumes a save not yet detected by the automatic watcher', () async {
    final dir = project('moment-watch-manual-save-');
    File(p.join(dir, 'view.dart')).writeAsStringSync('before');
    var runs = 0;
    final watcher = watch(
      dir,
      interval: 10,
      debounce: 5,
      machine: Machine(restartWith: (_) async => runs++),
      moments: Runtime(restoration: () => {'name': 'inbox'}),
    );
    File(p.join(dir, 'view.dart')).writeAsStringSync('after');
    await watcher.refresh();
    await sleep(65);
    expect(runs, 1, reason: 'The same saved source must not trigger a second automatic restart');
  });

  test('a missing pause acknowledgement prevents machine restart; a compiler failure releases frames', () async {
    final dir = project('moment-watch-handoff-');
    var ready = false, runs = 0, resumed = 0;
    final watcher = watch(
      dir,
      enabled: false,
      machine: Machine(
        restartWith: (_) async {
          runs++;
          throw const MomentsError('Compilation failed');
        },
      ),
      moments: Runtime(
        prepare: () async {
          if (!ready) throw const MomentsError('No runtime acknowledgement');
          return () => resumed++;
        },
      ),
    );
    expect((await watcher.refresh())['error'], contains('acknowledgement'));
    expect(runs, 0);
    ready = true;
    expect((await watcher.refresh())['error'], contains('Compilation failed'));
    expect(runs, 1);
    expect(resumed, 1);
  });

  test('backend edit updates service before Flutter and failure releases UI without a Dart restart', () async {
    final dir = temporary('moment-watch-backend-');
    var source = 'one', fail = false, resumes = 0;
    final events = <String>[];
    final watcher = watch(
      dir,
      paths: const [],
      debounce: 5,
      backend: Backend(() => source, () async {
        events.add('backend');
        if (fail) throw const MomentsError('Elixir compile failed');
      }),
      machine: Machine(restartWith: (_) async => events.add('flutter')),
      moments: Runtime(
        prepare: () async =>
            () => resumes++,
        restoration: () => {'name': 'inbox'},
      ),
    );
    source = 'two';
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(events, ['backend', 'flutter']);
    expect(resumes, 1);
    fail = true;
    source = 'bad';
    await eventually(() => watcher.status()['phase'] == 'error');
    expect(watcher.status()['failureStage'], 'backend');
    expect(resumes, 2);
    await sleep(50);
    expect(events, ['backend', 'flutter', 'backend']);
    fail = false;
    source = 'fixed';
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(resumes, 3);
  });

  test('native launch excludes web flags and daemon identity is cleared when Flutter stops', () async {
    expect(flutterTarget('linux').args, ['-d', 'linux']);
    expect(flutterTarget('web-server', 5196).args, ['-d', 'web-server', '--web-hostname=127.0.0.1', '--web-port=5196']);
    expect(() => flutterTarget('unexpected-device'), throwsA(predicate((e) => '$e'.contains('Supported'))));
    final child = Child();
    final machine = FlutterMachine(child, log: (_) {});
    try {
      expect(machine.device(), isNull);
      child.write(
        '[{"event":"app.start","params":{"appId":"native","deviceId":"linux"}},{"event":"app.started","params":{"appId":"native"}}]\n',
      );
      await sleep(5);
      expect(machine.device(), 'linux');
      expect(machine.ready(), isTrue);
      child.write('[{"event":"app.stop","params":{"appId":"native"}}]\n');
      await sleep(5);
      expect(machine.device(), isNull);
      expect(machine.ready(), isFalse);
    } finally {
      machine.close();
    }
  });

  test('reload compiler response requires a subsequent frame and never pauses or restores UI', () async {
    final dir = temporary('moment-reload-');
    final events = <String>[];
    var compiled = false, observed = false, marked = false;
    final watcher = watch(
      dir,
      paths: const [],
      enabled: false,
      restoreTimeout: 300,
      machine: Machine(
        restartWith: (fullRestart) async {
          expect(fullRestart, isFalse);
          events.add('compiler');
          compiled = true;
          return null;
        },
      ),
      moments: Runtime(
        reload: () => true,
        prepare: () => fail('Reload must not pause frames'),
        frame: () {
          expect(compiled, isTrue);
          events.add('frame');
          return 'challenge';
        },
        frameAfterId: (id) {
          expect(id, 'challenge');
          return observed ? {'name': 'inbox'} : null;
        },
        marked: () => marked = true,
        cancel: (id) => events.add('cancel:$id'),
      ),
    );
    final pending = watcher.refresh();
    await eventually(() => watcher.status()['phase'] == 'restoring');
    expect(marked, isFalse);
    observed = true;
    final result = await pending;
    expect(result['phase'], 'ready');
    expect(result['strategy'], 'reload');
    expect(marked, isTrue);
    expect(events, ['compiler', 'frame', 'cancel:challenge']);
  });

  test('compiled reload without a frame fails without retrying or marking code applied', () async {
    final dir = temporary('moment-reload-timeout-');
    var runs = 0, cancelled = 0;
    final watcher = watch(
      dir,
      paths: const [],
      enabled: false,
      restoreTimeout: 10,
      machine: Machine(restartWith: (_) async => runs++),
      moments: Runtime(
        reload: () => true,
        frame: () => '1',
        frameAfterId: (_) => null,
        marked: () => fail('No frame proof'),
        cancel: (_) => cancelled++,
      ),
    );
    final result = await watcher.refresh();
    expect(result['phase'], 'error');
    expect(result['error'], contains('post-compile frame'));
    expect(runs, 1);
    expect(cancelled, 1);
  });

  test('explicit initialization and backend edits force restart even on a reload-capable runtime', () async {
    final dir = temporary('moment-force-restart-');
    var source = 'one';
    final modes = <bool>[];
    final watcher = watch(
      dir,
      paths: const [],
      enabled: false,
      backend: Backend(() => source, () async {}),
      machine: Machine(restartWith: (fullRestart) async => modes.add(fullRestart)),
      moments: Runtime(reload: () => true, restoration: () => {'name': 'inbox'}),
    );
    expect((await watcher.refresh(restart: true))['strategy'], 'restart');
    source = 'two';
    expect((await watcher.refresh())['strategy'], 'restart');
    expect(modes, [true, true]);
  });

  test('machine sends an actual reload request rather than fullRestart', () async {
    final child = Child();
    final machine = FlutterMachine(child, log: (_) {});
    try {
      child.write(
        '[{"event":"app.start","params":{"appId":"app"}},{"event":"app.started","params":{"appId":"app"}}]\n',
      );
      await sleep(5);
      child.commands.first.then((command) {
        expect((command['params']! as Map)['fullRestart'], false);
        child.write(
          '${jsonEncode([
            {
              'id': command['id'],
              'result': {'code': 0},
            },
          ])}\n',
        );
      });
      await machine.restart(fullRestart: false);
    } finally {
      machine.close();
    }
  });

  test('automatic refresh queues source changes while an interrupted journey holds the instance', () async {
    final dir = project('moment-watch-lease-');
    var allowed = false, runs = 0;
    final watcher = watch(
      dir,
      debounce: 10,
      automaticAllowed: () => allowed,
      machine: Machine(restartWith: (_) async => runs++),
      moments: Runtime(restoration: () => {'name': 'inbox'}),
    );
    File(p.join(dir, 'view.dart')).writeAsStringSync('two');
    await eventually(() => watcher.status()['pending'] == true);
    await sleep(40);
    expect(runs, 0);
    allowed = true;
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(runs, 1);
  });

  test('machine surfaces compiler diagnostic events without flooding status with trace logs', () async {
    final child = Child(), logs = <String>[];
    final machine = FlutterMachine(child, log: logs.add);
    for (final level in ['trace', 'status', 'warning', 'error']) {
      child.write(
        '${jsonEncode([
          {
            'event': 'daemon.logMessage',
            'params': {'level': level, 'message': '$level detail'},
          },
        ])}\n',
      );
    }
    await sleep(10);
    expect(logs, ['warning detail', 'error detail']);
    machine.close();
  });

  test('startup queues edits until a runtime observes, then applies the latest source once', () async {
    final dir = project('moment-watch-startup-');
    var observed = false, runs = 0, applied = 0;
    final watcher = watch(
      dir,
      debounce: 10,
      machine: Machine(restartWith: (_) async => runs++),
      moments: Runtime(
        claim: () => observed,
        observed: () => observed,
        restoration: () => {'name': 'inbox'},
        marked: () => applied++,
      ),
    );
    await eventually(() => watcher.status()['phase'] == 'waiting-runtime');
    File(p.join(dir, 'view.dart')).writeAsStringSync('two');
    await eventually(() => watcher.status()['pending'] == true);
    File(p.join(dir, 'view.dart')).writeAsStringSync('three');
    await sleep(60);
    expect(runs, 0);
    expect(applied, 0);
    expect(watcher.status()['phase'], 'waiting-runtime');
    expect(watcher.status()['error'], isNull);
    final manual = await watcher.refresh();
    expect(manual['phase'], 'waiting-runtime');
    expect(manual['pending'], isTrue);
    expect(runs, 0);
    observed = true;
    await eventually(() => watcher.status()['phase'] == 'ready');
    expect(runs, 1);
    expect(applied, 1);
    expect(watcher.status()['pending'], isFalse);
  });

  test('compiled app blocked by authentication is unavailable, never marked applied', () async {
    final dir = temporary('moment-watch-blocked-');
    var marked = 0;
    final watcher = watch(
      dir,
      paths: const [],
      enabled: false,
      restoreTimeout: 500,
      machine: Machine(restartWith: (_) async => null),
      moments: Runtime(
        checkpoint: {'client': 'old', 'revision': 'r'},
        blocker: (checkpoint, fullRestart) {
          expect(fullRestart, isTrue);
          return {'reason': 'authentication-required', 'client': 'new', 'revision': 'r'};
        },
        restoration: () => {'name': 'must-not-win'},
        marked: () => marked++,
      ),
    );
    final status = await watcher.refresh();
    expect(status['phase'], 'error');
    expect(status['failureStage'], 'runtime');
    expect((status['blocker']! as Map)['reason'], 'authentication-required');
    expect(status['error'], contains('Sign in'));
    expect(marked, 0);
    expect(status['compileMs'], isA<num>());
  });
}
