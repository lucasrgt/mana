import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/declaration_sources.dart';
import 'package:moments/src/journey.dart';
import 'package:moments/src/preparation_retry.dart';
import 'package:moments/src/restart_handoff.dart';
import 'package:moments/src/services.dart';
import 'package:moments/src/timing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

Map<String, Object?> sample() => {
  'clock': 'dart-monotonic',
  'elapsedMs': 100,
  'marks': {
    'main': {'ms': 0, 'visibility': 'visible', 'focused': false},
  },
  'spans': [
    {'stage': 'authentication', 'startMs': 2, 'durationMs': 32, 'outcome': 'ok'},
  ],
};

ServiceDefinition service({required bool idempotent}) => ServiceDefinition(
  name: 'api',
  cwd: '/',
  port: 1,
  ready: () async => true,
  serve: const ['serve'],
  prepare: const ['prepare'],
  prepareIdempotent: idempotent,
);

void main() {
  group('timing', () {
    test('diagnostics only preserve bounded numeric timings and declared labels', () {
      final input = sample()..['secret'] = 'must-not-persist';
      ((input['spans']! as List).first as Map)['token'] = 'must-not-persist';
      expect(sanitizeTiming(input), sample());
      expect(sanitizeTiming({...sample(), 'spans': List.filled(33, (sample()['spans']! as List).first)}), isNull);
      for (final invalid in <Object?>[double.nan, -1, double.infinity, '10']) {
        expect(sanitizeTiming({...sample(), 'elapsedMs': invalid}), isNull, reason: '$invalid');
      }
      expect(
        sanitizeTiming({
          ...sample(),
          'marks': {
            'password': {'ms': 1, 'visibility': 'visible'},
          },
        }),
        isNull,
      );
      expect(
        sanitizeTiming({
          ...sample(),
          'spans': [
            {...((sample()['spans']! as List).first as Map).cast<String, Object?>(), 'durationMs': 101},
          ],
        }),
        isNull,
      );
      expect(sanitizeTiming(null), isNull);
    });
  });

  group('preparation retry', () {
    test('only explicit idempotent service retries preserve a committed base', () {
      final state = {
        'phase': 'ready',
        'launch': {'route': '/inbox'},
        'preparation': {'stage': 'services', 'moment': 'inbox'},
      };
      final before = jsonEncode(state);
      void retry(
        Map<String, Object?>? instance, {
        bool retryPreparation = true,
        String initialMoment = 'inbox',
        List<ServiceDefinition>? services,
        Map<String, Object?>? journey,
      }) => validatePreparationRetry(
        instance,
        retryPreparation: retryPreparation,
        initialMoment: initialMoment,
        services: services ?? [service(idempotent: true)],
        journey: journey,
      );
      retry(state);
      expect(jsonEncode(state), before);
      expect(() => retry(state, retryPreparation: false), throwsA(anything));
      expect(() => retry(state, initialMoment: 'other'), throwsA(anything));
      expect(() => retry(state, services: [service(idempotent: false)]), throwsA(anything));
      expect(() => retry(state, services: const []), throwsA(anything));
      for (final stage in ['startup', 'base', 'recipe']) {
        expect(
          () => retry({
            ...state,
            'preparation': {'stage': stage, 'moment': 'inbox'},
          }),
          throwsA(anything),
          reason: stage,
        );
      }
      expect(() => retry({...state, 'phase': 'seeding'}), throwsA(anything));
      expect(() => retry({...state, 'launch': null}), throwsA(anything));
      expect(() => retry(state, journey: {'phase': 'attention'}), throwsA(anything));
      expect(() => retry(null), throwsA(anything));
      expect(parseArgs(['up', 'inbox', '--retry-preparation']).retryPreparation, isTrue);
      expect(() => parseArgs(['check', 'inbox', '--retry-preparation']), throwsA(anything));
    });
  });

  group('declaration sources', () {
    ({String root, String project, String file, Map<String, Object?> source, String manifest, String config})
    fixture() {
      final root = temporary('mana-declaration-');
      final project = p.join(root, 'app'), server = p.join(root, 'server');
      Directory(p.join(project, 'moments')).createSync(recursive: true);
      Directory(server).createSync();
      final file = p.join(server, 'tasks.ex');
      File(file).writeAsStringSync('declaration');
      return (
        root: root,
        project: project,
        file: file,
        source: {'file': '../../server/tasks.ex', 'sha256': sha256.convert(utf8.encode('declaration')).toString()},
        manifest: p.join(project, 'moments/manifest.json'),
        config: p.join(project, 'moments/sources.json'),
      );
    }

    void declare(String config) => writeJson(config, {
      'version': 1,
      'roots': [
        {'name': 'server', 'path': '../server'},
      ],
    });

    test('sibling declarations require explicit roots and retain portable proof identity', () {
      final f = fixture();
      Map<String, Object?> read() => declarationSource(f.project, f.manifest, f.source);
      expect(read, throwing('outside configured'));
      declare(f.config);
      final proof = read();
      expect(proof['file'], 'server:tasks.ex');
      expect(proof['status'], 'current');
      expect(proof['configDigest'], matches(RegExp(r'^[a-f0-9]{64}$')));
      File(f.file).writeAsStringSync('changed');
      expect(read()['status'], 'stale');
      writeJson(f.config, {'version': 1, 'roots': <Object?>[]});
      expect(read, throwing('outside configured'));
    });

    test('source symlinks cannot escape declared roots and source metadata cannot pick arbitrary files', () {
      final f = fixture();
      declare(f.config);
      final outside = p.join(f.root, 'secret.ex');
      File(outside).writeAsStringSync('secret');
      File(f.file).deleteSync();
      Link(f.file).createSync(outside);
      expect(() => declarationSource(f.project, f.manifest, f.source), throwing('outside configured'));
      for (final file in [outside, '../../server/tasks.json']) {
        expect(
          () => declarationSource(f.project, f.manifest, {...f.source, 'file': file}),
          throwing('Invalid declaration'),
        );
      }
    });

    test('invalid root configuration and oversized source fail without source content in diagnostics', () {
      final f = fixture();
      Map<String, Object?> read() => declarationSource(f.project, f.manifest, f.source);
      File(f.config).writeAsStringSync('PRIVATE CONFIG');
      expect(read, throwsA(predicate((e) => '$e' == 'Invalid moments/sources.json')));
      writeJson(f.config, {
        'version': 1,
        'roots': [
          {'name': 'server', 'path': '/'},
        ],
      });
      expect(read, throwing('Invalid declaration'));
      declare(f.config);
      File(f.file).writeAsStringSync('x' * (2 * 1024 * 1024 + 1));
      expect(read, throwing('exceeds'));
    });
  });

  group('journey outcomes', () {
    test('a dispatched action with a false postcondition fails, retains evidence and is never tapped twice', () async {
      var taps = 0;
      final report = <String, Object?>{};
      final scene = {
        'steps': [
          {
            'name': 'archive',
            'kind': 'tap',
            'target': 'archive-item',
            'until': ['persisted'],
          },
        ],
        'checks': [
          {'name': 'persisted', 'kind': 'backend_equals'},
        ],
      };
      Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
        if (path == '/journey/tap') {
          taps++;
          return {...data!, 'status': 'dispatched'};
        }
        if (path == '/moments/look') {
          return {
            'revision': 'r',
            'observed': {
              'client': 'c',
              'projection': {'archived': false},
            },
          };
        }
        if (path == '/moments/inspect') {
          return {
            'moment': {'revision': 'r'},
            'screen': {
              'lastReported': {
                'matchesRevision': true,
                'projection': {'archived': false},
              },
            },
          };
        }
        throw Exception('Unexpected request');
      }

      final outcomes = [
        {'name': 'persisted', 'status': 'failed', 'expected': true, 'observed': false, 'identityMatched': true},
      ];
      await expectLater(
        executeSteps(
          scene: scene,
          request: request,
          revision: 'r',
          client: 'c',
          expected: <String, Object?>{},
          properties: <String, Object?>{},
          report: report,
          evaluate: (_, {required expected, required observed, required properties, required backend}) => outcomes,
          timeout: 0,
        ),
        throwsA(predicate((e) => e is JourneyError && e.status == 'failed')),
      );
      final step = ((report['steps']! as List).first as Map).cast<String, Object?>();
      expect(taps, 1);
      expect(step['dispatch'], 'dispatched');
      expect(step['status'], 'failed');
      expect(step['checks'], outcomes);
      expect(step['durationMs'] as num, greaterThanOrEqualTo(0));
      expect(step['postconditionMs'] as num, greaterThanOrEqualTo(0));
    });

    test('a transport interruption is unavailable and never copies arbitrary exception text into a step', () async {
      final report = <String, Object?>{};
      final scene = {
        'steps': [
          {
            'name': 'archive',
            'kind': 'tap',
            'target': 'item',
            'until': ['persisted'],
          },
        ],
        'checks': <Object?>[],
      };
      await expectLater(
        executeSteps(
          scene: scene,
          request: (path, [data]) async => throw Exception('PRIVATE-TRANSPORT-TEXT'),
          revision: null,
          client: null,
          expected: null,
          properties: null,
          report: report,
          evaluate: (_, {required expected, required observed, required properties, required backend}) => const [],
        ),
        throwsA(anything),
      );
      final step = ((report['steps']! as List).first as Map).cast<String, Object?>();
      expect(step['status'], 'unavailable');
      expect(step['dispatch'], 'unknown');
      expect(step['durationMs'] as num, greaterThanOrEqualTo(0));
      expect(jsonEncode(report).contains('PRIVATE-TRANSPORT-TEXT'), isFalse);
    });

    test('the concise CLI names the postcondition that failed inside the gesture', () {
      final text = formatResult({
        'status': 'failed',
        'checks': <Object?>[],
        'name': 'archive',
        'steps': [
          {
            'name': 'press',
            'status': 'failed',
            'dispatch': 'dispatched',
            'checks': [
              {'name': 'persisted', 'status': 'failed'},
            ],
          },
        ],
      }, CliOptions()..command = 'run');
      expect(text, matches(RegExp('persisted.*postcondition of press')));
    });

    test('an invalidated observation is not retained as a current failed criterion', () async {
      final report = <String, Object?>{};
      var inspections = 0;
      final scene = {
        'steps': [
          {
            'name': 'archive',
            'kind': 'tap',
            'target': 'item',
            'until': ['persisted'],
          },
        ],
        'checks': [
          {'name': 'persisted'},
        ],
      };
      Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async => path == '/journey/tap'
          ? {...data!, 'status': 'dispatched'}
          : path == '/moments/look'
          ? {
              'revision': 'r',
              'observed': {'client': 'c', 'projection': <String, Object?>{}},
            }
          : {
              'moment': {'revision': 'r'},
              'screen': {
                'lastReported': {'matchesRevision': true, 'projection': <String, Object?>{}},
              },
            };
      await expectLater(
        executeSteps(
          scene: scene,
          request: request,
          revision: 'r',
          client: 'c',
          expected: null,
          properties: null,
          report: report,
          poll: 0,
          evaluate: (_, {required expected, required observed, required properties, required backend}) => [
            {'name': 'persisted', 'status': 'failed'},
          ],
          validateInspection: (_) {
            if (++inspections == 2) throw const JourneyError('Runtime changed');
          },
        ),
        throwsA(predicate((e) => e is JourneyError && e.status == 'unavailable')),
      );
      final step = ((report['steps']! as List).first as Map).cast<String, Object?>();
      expect(inspections, 2);
      expect(step['status'], 'unavailable');
      expect(step.containsKey('checks'), isFalse);
    });
  });

  group('restart handoff', () {
    test('restart requires the current runtime acknowledgement; failure resumes only that runtime', () async {
      final handoff = RestartHandoff(notify: () {});
      final prepared = handoff.prepare('old');
      final control = handoff.control('old')!;
      expect(control['phase'], 'pause');
      expect(handoff.control('other'), isNull);
      expect(handoff.acknowledge({...control, 'client': 'other', 'phase': 'paused'}), isFalse);
      expect(handoff.acknowledge({...control, 'id': 'stale', 'client': 'old', 'phase': 'paused'}), isFalse);
      expect(handoff.acknowledge({...control, 'client': 'old', 'phase': 'paused'}), isTrue);
      final resume = await prepared;
      expect(handoff.control('old'), isNull);
      resume();
      resume();
      expect(handoff.control('old')!['phase'], 'resume');
      expect(handoff.acknowledge({...control, 'client': 'old', 'phase': 'resumed'}), isTrue);
      expect(handoff.control('old'), isNull);
    });

    test('missing acknowledgement aborts restart and a late pause must be released', () async {
      final handoff = RestartHandoff(notify: () {}, timeout: const Duration(milliseconds: 10));
      final prepared = handoff.prepare('old');
      final control = handoff.control('old')!;
      await expectLater(prepared, throwing('did not prepare'));
      expect(handoff.control('old')!['phase'], 'resume');
      expect(handoff.acknowledge({...control, 'client': 'old', 'phase': 'paused'}), isFalse);
      expect(handoff.acknowledge({...control, 'client': 'old', 'phase': 'resumed'}), isTrue);
      await expectLater(handoff.prepare(null), throwing('No Flutter runtime'));
    });

    test('a new runtime retires old control without pausing the new screen', () async {
      final handoff = RestartHandoff(notify: () {});
      final prepared = handoff.prepare('old');
      final control = handoff.control('old')!;
      handoff.acknowledge({...control, 'client': 'old', 'phase': 'paused'});
      final resume = await prepared;
      handoff.claim('new');
      resume();
      expect(handoff.control('new'), isNull);
      expect(handoff.control('old'), isNull);
    });

    test('takeover during preparation cancels that attempt', () async {
      final handoff = RestartHandoff(notify: () {});
      final prepared = handoff.prepare('old');
      handoff.claim('new');
      await expectLater(prepared, throwing('runtime changed'));
      expect(handoff.control('new'), isNull);
    });
  });
}
