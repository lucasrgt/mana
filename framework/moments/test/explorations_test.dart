import 'dart:io';

import 'package:moments/src/errors.dart';
import 'package:moments/src/explorations.dart';
import 'package:moments/src/format.dart';
import 'package:moments/src/manifest.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _trace = {
  'property': 'invariant',
  'resource': 'MyApp.Ticket',
  'verb': 'closed_has_reason',
  'detail': 'every closed ticket says why: closed without a reason',
  'moves': [
    {'kind': 'start', 'actor': 'agent', 'verb': 'start', 'resource': 'MyApp.Ticket', 'params': {}},
    {
      'kind': 'verb',
      'actor': 'agent',
      'verb': 'close',
      'ref': ['MyApp.Ticket', 0],
    },
  ],
};

/// An app whose manifest has one screen Moment and the exploration Moments
/// [explored] names, as `mix moments.export` writes them.
String app({List<String> explored = const ['closed-ticket']}) {
  final project = temporary('moments-explorations-');
  writeJson(p.join(project, 'moments/manifest.json'), {
    'version': 3,
    'protocol': protocol,
    'watch': <Object?>[],
    'properties': <String, Object?>{},
    'moments': {
      'front': {
        'description': 'The front page',
        'backend': {'recipe': 'front'},
      },
      for (final name in explored)
        name: {
          'description': 'Found by Mana.Explore: invariant breaks for MyApp.Ticket.closed_has_reason',
          'checks': [
            {'name': 'invariant', 'kind': 'property'},
          ],
          'steps': <Object?>[],
          'exploration': {
            'file': '../../backend/priv/moments/explorations/$name.json',
            'sha256': '0' * 64,
            'trace': _trace,
          },
        },
    },
  });
  return project;
}

Map<String, Object?> _moments(String project) =>
    (readManifest(p.join(project, 'moments/manifest.json'))['moments']! as Map).cast();

void main() {
  group('an exploration Moment runs', () {
    late Map<String, Object?> exploration;
    setUp(() => exploration = explorationOf(_moments(app())['closed-ticket'])!);

    test('by the backend replaying its trace: failed while the property breaks, passed once it holds', () async {
      final bodies = <Object?>[];
      var fixed = false;
      Future<Map<String, Object?>> call(String recipe, String operation, Map<String, Object?> body) async {
        bodies.add([recipe, operation, body]);
        return fixed
            ? {'status': 'passed', 'property': 'invariant'}
            : {
                'status': 'failed',
                'violation': {'property': 'invariant', 'detail': 'closed without a reason'},
              };
      }

      final failed = await checkExploration(call, 'closed-ticket', exploration);
      expect(bodies.single, [
        '_explorations',
        'check',
        {'trace': _trace},
      ]);
      expect(failed['status'], 'failed');
      expect(failed['reason'], 'invariant breaks: closed without a reason');
      expect(failed['checks'], [
        {'name': 'invariant', 'kind': 'property', 'status': 'failed'},
      ]);
      fixed = true;
      final passed = await checkExploration(call, 'closed-ticket', exploration);
      expect(passed['status'], 'passed');
      expect(passed.containsKey('reason'), isFalse);
    });

    test('unavailable, never passed, when the backend cannot replay it or answers something else', () async {
      final refused = await checkExploration(
        (_, _, _) async => throw const MomentsError('Recipe _explorations check failed (422)'),
        'closed-ticket',
        exploration,
      );
      expect(refused['status'], 'unavailable');
      expect(refused['reason'], contains('422'));
      expect(refused['checks'], isEmpty);
      final odd = await checkExploration((_, _, _) async => {'status': 'maybe'}, 'closed-ticket', exploration);
      expect(odd['status'], 'unavailable');
    });

    test('in the suite, the exploration Moments only, as many at once as there are workers', () async {
      final moments = _moments(app(explored: ['a', 'b', 'c']));
      var running = 0, most = 0;
      final events = <Map<String, Object?>>[];
      final results = await runExplorations(
        call: (_, _, _) async {
          most = ++running > most ? running : most;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          running--;
          return {'status': 'passed'};
        },
        moments: moments,
        names: ['c', 'a', 'b'],
        workers: 2,
        emit: events.add,
      );
      expect(most, 2);
      expect([for (final r in results) r['name']], ['c', 'a', 'b'], reason: 'in the order asked');
      expect(events.map((e) => e['phase']).toSet(), {'moment'});
      expect(events, hasLength(3));
      final summary = explorationSummary(results, workers: 2, wallMs: 30);
      expect(summary['status'], 'passed');
      expect(summary['runtime'], 'backend');
      expect(
        explorationSummary(
          [
            ...results,
            {'status': 'failed'},
          ],
          workers: 2,
          wallMs: 1,
        )['status'],
        'failed',
      );
      expect(
        explorationSummary(
          [
            ...results,
            {'status': 'unavailable'},
          ],
          workers: 2,
          wallMs: 1,
        )['status'],
        'unavailable',
      );
    });
  });

  test('its map entry says what broke and how to get there, and goes when no exploration is declared', () {
    final project = app();
    writeExplorationMap(project);
    final map = parseMap(File(p.join(project, 'moments/explorations.md')).readAsStringSync());
    expect(map.order, ['closed-ticket']);
    final state = map.states['closed-ticket']!;
    expect(state.run, (executor: 'mana-explore', ref: '../backend/priv/moments/explorations/closed-ticket.json'));
    expect(state.checks.single, 'invariant holds for MyApp.Ticket closed_has_reason (Mana.Explore found it broken)');
    expect(state.describe, contains('closed without a reason'));
    expect(
      state.describe,
      contains('agent starts start on MyApp.Ticket, then agent performs close on MyApp.Ticket #0'),
    );
    writeJson(p.join(project, 'moments/manifest.json'), {
      ...(readJson(p.join(project, 'moments/manifest.json'))! as Map),
      'moments': {'front': _moments(project)['front']},
    });
    writeExplorationMap(project);
    expect(File(p.join(project, 'moments/explorations.md')).existsSync(), isFalse);
  });

  test('it is listed as an exploration and has no screen to open', () {
    final project = app();
    final manifest = p.join(project, 'moments/manifest.json');
    expect(
      {for (final entry in manifestCatalog(manifest)) entry['name']: entry['executor']},
      {'front': 'backend-sandbox', 'closed-ticket': 'mana-explore'},
    );
    expect(
      () => refuseExplorationUi(manifest, 'closed-ticket'),
      throwsA(predicate((e) => '$e'.contains('moments suite closed-ticket'))),
    );
    refuseExplorationUi(manifest, 'front');
  });

  group('CLI', () {
    setUpAll(compileCli);

    test('open, up and profile refuse an exploration Moment before anything starts', () async {
      final project = app();
      for (final command in ['open', 'up', 'profile']) {
        final run = await moments([command, 'closed-ticket'], cwd: project);
        expect(run.code, 2, reason: command);
        expect(run.stdout, contains('exploration Moment'), reason: command);
      }
    });
  });
}
