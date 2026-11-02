import 'package:moments/src/check.dart' show evaluateChecks;
import 'package:moments/src/journey.dart';
import 'package:moments/src/json.dart';
import 'package:moments/src/progress.dart';
import 'package:test/test.dart';

Matcher journeyError(String text, [String status = 'unavailable']) =>
    throwsA(predicate((e) => e is JourneyError && e.message.contains(text) && e.status == status, 'mentions "$text"'));

Future<void> sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

const scene = {
  'steps': [
    {
      'name': 'save',
      'kind': 'tap',
      'target': 'form.save',
      'until': ['saved'],
    },
  ],
  'checks': [
    {'name': 'saved', 'kind': 'ui_equals', 'field': 'status', 'equals': 'saved', 'scope': 'step'},
    {'name': 'shown', 'kind': 'ui_equals', 'field': 'status', 'equals': 'saved'},
  ],
};

/// An app whose save takes [backendMs] on the server: it shows a request in
/// flight ([reports] activity) until the answer lands, then the new status.
({Request request, Map<String, Object?> report}) app({
  required int backendMs,
  bool reportsActivity = true,
  bool endless = false,
}) {
  final report = <String, Object?>{};
  double? tapped;
  var sequence = 0;
  bool done() => !endless && tapped != null && nowMs() - tapped! >= backendMs;
  Map<String, Object?> projection() => {'route': '/form', 'status': done() ? 'saved' : 'saving'};
  Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
    if (path == '/journey/tap') {
      tapped = nowMs();
      return {...data!, 'status': 'dispatched', 'transport': 'flutter-pointer'};
    }
    if (path.startsWith('/moments/look')) {
      // The bridge holds `look?after=` until the next report or 250 ms.
      if (path.contains('after=')) await sleep(20);
      return {
        'revision': 'r',
        'observation': 1,
        'observed': {'client': 'c', 'projection': projection()},
        if (reportsActivity) 'activity': {'inFlight': done() ? 0 : 1, 'sequence': ++sequence},
      };
    }
    return {
      'moment': {'revision': 'r'},
      'screen': {
        'lastReported': {'matchesRevision': true, 'projection': projection()},
      },
    };
  }

  return (request: request, report: report);
}

Future<void> run(({Request request, Map<String, Object?> report}) app, {int timeout = 150, int limit = 2000}) =>
    executeSteps(
      scene: scene,
      request: app.request,
      revision: 'r',
      client: 'c',
      expected: {'route': '/form', 'status': 'saving'},
      properties: null,
      evaluate: evaluateChecks,
      report: app.report,
      timeout: timeout,
      limit: limit,
      poll: 1,
    );

Map<String, Object?> receipt(Map<String, Object?> report) => ((report['steps']! as List).single as Map).cast();

void main() {
  group('ProgressWait', () {
    test('an app that shows nothing gets its idle budget, measured from the start', () async {
      final wait = ProgressWait(idleMs: 60, limitMs: 1000);
      final look = {
        'observed': {
          'projection': {'a': 1},
        },
      };
      expect(wait.observe(look), isFalse);
      await sleep(70);
      expect(wait.observe(look), isFalse);
      expect(wait.expired, isTrue);
      expect(wait.reason, 'idle');
    });

    test('a changed report, a request in flight or a finished request each count as progress', () {
      final wait = ProgressWait(idleMs: 60, limitMs: 1000);
      Map<String, Object?> look(int value, {int? inFlight, int? sequence, List<String>? offered}) => {
        'observed': {
          'projection': {'a': value},
          'offered': ?offered,
        },
        if (inFlight != null) 'activity': {'inFlight': inFlight, 'sequence': sequence},
      };
      expect(wait.observe(look(1)), isFalse, reason: 'the first sample is the baseline');
      expect(wait.observe(look(1)), isFalse);
      expect(wait.observe(look(2)), isTrue);
      expect(wait.observe(look(2, offered: ['booking.pay'])), isTrue);
      expect(wait.observe(look(2, inFlight: 1, sequence: 1, offered: ['booking.pay'])), isTrue);
      expect(wait.observe(look(2, inFlight: 0, sequence: 2, offered: ['booking.pay'])), isTrue);
      expect(wait.observe(look(2, inFlight: 0, sequence: 2, offered: ['booking.pay'])), isFalse);
      expect(wait.receipt(), containsPair('progressSigns', 4));
      expect(wait.receipt(), containsPair('activityReported', true));
    });

    test('progress never extends the wait past its limit', () async {
      final wait = ProgressWait(idleMs: 1000, limitMs: 50);
      await sleep(60);
      wait.observe({
        'activity': {'inFlight': 3, 'sequence': 1},
      });
      expect(wait.expired, isTrue);
      expect(wait.reason, 'limit');
    });
  });

  group('step postconditions', () {
    test('a slow backend that the app is still waiting on passes after the idle budget', () async {
      final slow = app(backendMs: 600);
      await run(slow, timeout: 150);
      final step = receipt(slow.report);
      expect(step['status'], 'passed');
      expect(step['postconditionMs'] as num, greaterThan(600));
      final wait = (step['wait']! as Map).cast<String, Object?>();
      expect(wait['idleBudgetMs'], 150);
      expect(wait['limitMs'], 2000);
      expect(wait['activityReported'], isTrue);
      expect(wait['busyMs'] as num, greaterThan(300));
      expect(wait['progressSigns'] as int, greaterThan(1));
      expect(wait['lookMs'] as num, greaterThan(0));
      expect(wait['inspectMs'] as num, greaterThanOrEqualTo(0));
    });

    test('without activity reports the same step fails at the idle budget, as a fixed budget did', () async {
      final quiet = app(backendMs: 600, reportsActivity: false);
      await expectLater(run(quiet, timeout: 150), journeyError('no progress for 0.15 s', 'failed'));
      final step = receipt(quiet.report);
      expect(step['postconditionMs'] as num, lessThan(500));
      expect((step['wait']! as Map)['activityReported'], isFalse);
    });

    test('an app that never settles stops at the hard limit, never retrying the gesture', () async {
      final stuck = app(backendMs: 0, endless: true);
      await expectLater(
        run(stuck, timeout: 150, limit: 500),
        journeyError('still progressing at the 0.50 s limit', 'failed'),
      );
      final step = receipt(stuck.report);
      expect(step['postconditionMs'] as num, inInclusiveRange(500, 1500));
      expect(step['dispatch'], 'dispatched');
    });
  });
}
