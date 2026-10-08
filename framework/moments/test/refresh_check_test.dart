import 'dart:convert';
import 'dart:io';

import 'package:moments/src/check.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// A bridge whose refresh attempt 7 compiles, restores and then reports.
final class Fixture {
  Fixture({
    this.join = false,
    this.noChecks = false,
    this.changedMoment = false,
    this.changedState = false,
    this.unapplied = false,
    this.ui = const {},
    this.disconnect = false,
    this.waitingRuntime = false,
    this.held = false,
    this.superseded = false,
    this.duringCheck = false,
    this.compileError = false,
    this.restoreError = false,
    this.blocker,
    this.timeout = false,
    this.sourceChanges = false,
    this.runtime,
    this.pending = false,
    this.read = false,
  }) : project = temporary('refresh-check-') {
    _active = join;
    Directory(p.join(project, 'moments')).createSync();
    Directory(p.join(project, 'lib')).createSync();
    File(p.join(project, 'lib/view.dart')).writeAsStringSync('original');
    writeJson(p.join(project, 'moments/manifest.json'), {
      'watch': ['lib/view.dart'],
      'moments': {
        'inbox': {
          'checks': noChecks
              ? <Object?>[]
              : [
                  {'name': 'restored', 'kind': 'restored', 'field': 'filter', 'equals': 'reservation'},
                  {'name': 'unread', 'kind': 'backend_equals', 'field': 'allUnread', 'equals': true, 'match': 'ids'},
                ],
        },
      },
    });
  }

  final bool join, noChecks, changedMoment, changedState, unapplied, disconnect, waitingRuntime, held;
  final bool superseded, duringCheck, compileError, restoreError, timeout, sourceChanges, pending, read;
  final Map<String, Object?> ui;
  final String? blocker;
  final Map<String, Object?>? runtime;
  final String project;
  late bool _active;
  var _ready = false, _inspected = false, _statusReads = 0, starts = 0;
  final trace = <String>[];

  static const projection = {'route': '/notifications', 'filter': 'reservation', 'scrollOffset': 80, 'ids': 'record-1'};
  static final services = [
    {
      'name': 'backend',
      'phase': 'ready',
      'running': true,
      'codeChanged': false,
      'generation': '00000000-0000-4000-8000-000000000001',
      'source': {'current': 'a' * 64, 'applied': 'a' * 64},
    },
  ];

  Map<String, Object?> snapshot() => {
    'revision': changedMoment && _ready ? 'other' : 'revision',
    'state': {
      'name': 'inbox',
      'projection': changedState && _ready ? {...projection, 'scrollOffset': 10} : projection,
    },
    'codeChanged': unapplied && _ready ? true : !_ready,
    'observed': {
      'revision': 'revision',
      'client': _ready ? 'new-runtime' : 'old-runtime',
      'projection': {...projection, if (_ready) ...ui},
    },
  };

  Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
    trace.add(path);
    if (disconnect && path == '/dev/status') throw Exception('private backend token');
    switch (path) {
      case '/moments/look':
        return snapshot();
      case '/dev/refresh':
        expect(data, <String, Object?>{});
        starts++;
        _active = true;
        return {'id': 7, 'phase': 'compiling'};
      case '/dev/status':
        if (waitingRuntime) return {'phase': 'waiting-runtime', 'pending': true};
        if (held) return {'phase': 'idle', 'held': true};
        // A stale success is insufficient.
        if (!_active) return {'phase': 'ready', 'id': 6, 'moment': 'inbox'};
        _statusReads++;
        if ((superseded && _statusReads > 1) || (duringCheck && _inspected)) return {'id': 8, 'phase': 'compiling'};
        if (compileError && _statusReads > 1) {
          return {'id': 7, 'phase': 'error', 'compileMs': null, 'error': 'private compiler payload'};
        }
        if (restoreError && _statusReads > 1) return {'id': 7, 'phase': 'error', 'compileMs': 1};
        if (blocker != null && _statusReads > 1) {
          return {
            'id': 7,
            'phase': 'error',
            'compileMs': 1,
            'failureStage': 'runtime',
            'blocker': {'reason': blocker},
            'error': 'private session payload',
          };
        }
        if (timeout || _statusReads == 1) return {'id': 7, 'phase': 'compiling'};
        if (_statusReads == 2) return {'id': 7, 'phase': 'restoring', 'compileMs': 1};
        _ready = true;
        if (sourceChanges) File(p.join(project, 'lib/view.dart')).writeAsStringSync('edited during compile');
        return {
          'id': 7,
          'phase': 'ready',
          'services': services,
          'moment': 'inbox',
          'compileMs': 1,
          'restoreMs': 2,
          'totalMs': 3,
          'prepareMs': 0.1,
          'compilerMs': 0.9,
          'runtime': runtime,
          'pending': pending,
        };
      case '/moments/inspect':
        expect(_ready, isTrue, reason: 'Never inspect backend before the completed refresh');
        _inspected = true;
        return {
          'supervisor': {'phase': 'ready', 'services': services},
          'moment': {'revision': 'revision', 'codeChanged': false},
          'screen': {
            'lastReported': {'matchesRevision': true, 'projection': (snapshot()['observed']! as Map)['projection']},
          },
          'backend': {
            'status': 'ready',
            'projection': {'ids': 'record-1', 'allUnread': !read},
          },
        };
    }
    throw Exception('Unexpected request $path');
  }

  Future<Map<String, Object?>> run() => checkMoment(
    project: project,
    name: null,
    request: request,
    refresh: true,
    refreshTimeout: timeout ? 4 : 1000,
    poll: 1,
  );
}

String reportText(Map<String, Object?> result) => File(result['report']! as String).readAsStringSync();
Map<String, Object?> refresh(Map<String, Object?> result) => (result['refresh']! as Map).cast();

void main() {
  test(
    'refresh-check waits for the specific attempt, inspects the restored runtime and writes one combined report',
    () async {
      final f = Fixture();
      final result = await f.run();
      expect(result['status'], 'passed');
      expect(result['name'], 'inbox');
      expect(refresh(result)['id'], 7);
      expect(refresh(result)['mode'], 'started');
      expect(f.starts, 1);
      expect(
        f.trace.contains('/moments/open'),
        isFalse,
        reason: 'Reuse the restart restoration instead of navigating again',
      );
      final report = jsonDecode(reportText(result)) as Map;
      expect(report['operation'], 'refresh-check');
      expect(report['stage'], 'check');
      expect((report['refresh'] as Map)['totalMs'], 3);
      expect((report['checks'] as List).length, 2);
    },
  );

  test('joins an automatic refresh already running without a second restart', () async {
    final f = Fixture(join: true);
    final result = await f.run();
    expect(result['status'], 'passed');
    expect(refresh(result)['mode'], 'joined');
    expect(f.starts, 0);
  });

  for (final (label, make, status, stage) in <(String, Fixture Function(), String, String)>[
    ('compiler failure', () => Fixture(compileError: true), 'failed', 'compile'),
    ('restoration failure', () => Fixture(restoreError: true), 'unavailable', 'restore'),
    ('deadline without cancellation or automatic retry', () => Fixture(timeout: true), 'unavailable', 'compile'),
    ('superseded attempt', () => Fixture(superseded: true), 'unavailable', 'compile'),
    ('pending new edit', () => Fixture(pending: true), 'unavailable', 'restore'),
    ('Moment revision changed', () => Fixture(changedMoment: true), 'unavailable', 'restore'),
    ('saved projection changed', () => Fixture(changedState: true), 'unavailable', 'restore'),
    ('source changed during compilation', () => Fixture(sourceChanges: true), 'unavailable', 'restore'),
    ('code not applied', () => Fixture(unapplied: true), 'unavailable', 'restore'),
    ('UI lost scroll', () => Fixture(ui: {'scrollOffset': 0}), 'failed', 'check'),
    ('backend criterion fails', () => Fixture(read: true), 'failed', 'check'),
    ('another refresh during observation', () => Fixture(duringCheck: true), 'unavailable', 'check'),
    ('backend preparation', () => Fixture(held: true), 'unavailable', 'declaration'),
    ('no declared checks', () => Fixture(noChecks: true), 'unavailable', 'declaration'),
    ('transport failure', () => Fixture(disconnect: true), 'unavailable', 'declaration'),
  ]) {
    test(label, () async {
      final f = make();
      final result = await f.run();
      expect(result['status'], status);
      expect(result['stage'], stage);
      expect(result['exitCode'], status == 'failed' ? 1 : 2);
      expect(f.starts, lessThanOrEqualTo(1));
      if (stage != 'check') expect(f.trace.contains('/moments/inspect'), isFalse);
      if (f.noChecks || f.held) expect(f.starts, 0);
      expect(reportText(result).contains('private'), isFalse);
    });
  }

  test('runtime timing reaches the disposable report without becoming a criterion', () async {
    final runtime = {'clock': 'dart-monotonic', 'elapsedMs': 500, 'marks': <String, Object?>{}, 'spans': <Object?>[]};
    final result = await Fixture(runtime: runtime).run();
    expect(result['status'], 'passed');
    expect(refresh(result)['runtime'], runtime);
    expect(((jsonDecode(reportText(result)) as Map)['refresh'] as Map)['runtime'], runtime);
    expect(refresh(result)['compilerMs'], 0.9);
    expect(refresh(result)['prepareMs'], 0.1);
  });

  test('refresh-check preserves the queued startup edit instead of starting another attempt', () async {
    final f = Fixture(waitingRuntime: true);
    final result = await f.run();
    expect(result['status'], 'unavailable');
    expect(result['reason'], contains('Open the Flutter app first'));
    expect(f.starts, 0);
    expect(f.trace.contains('/moments/inspect'), isFalse);
  });

  for (final (blocker, message) in [
    ('authentication-required', 'Sign in through the app'),
    ('session-unavailable', 'Restore session access'),
  ]) {
    test('refresh-check reports $blocker without inspecting or replaying the journey', () async {
      final f = Fixture(blocker: blocker);
      final result = await f.run();
      expect(result['status'], 'unavailable');
      expect(result['exitCode'], 2);
      expect(result['stage'], 'restore');
      expect(refresh(result)['blocker'], blocker);
      expect(result['reason'], contains(message));
      expect(f.starts, 1);
      expect(f.trace.contains('/moments/inspect'), isFalse);
      expect(f.trace.contains('/moments/open'), isFalse);
      expect(reportText(result).contains('private'), isFalse);
    });
  }
}
