import 'dart:convert';
import 'dart:io';

import 'package:moments/src/backend_recipes.dart';
import 'package:moments/src/bridge.dart';
import 'package:moments/src/check.dart';
import 'package:moments/src/checkpoints.dart';
import 'package:moments/src/journey.dart';
import 'package:moments/src/preparation_retry.dart';
import 'package:moments/src/protocol.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'programs/interrupted_preparation.dart';
import 'support.dart';

/// The protocol capabilities `moments capabilities` declares beyond the data
/// situations (those are in situations_test.dart), one group per flag.

Matcher refusing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// A shop with a paid order and a refund of it: `shop` → `paid` → `refunded`,
/// each with a recipe of its own, and `receipt`, a child of `paid` that
/// declares no recipe.
String shop({Map<String, Map<String, Object?>> extra = const {}}) {
  final root = temporary('moments-conformance-');
  writeJson(p.join(root, 'moments/manifest.json'), {
    'version': 3,
    'protocol': protocol,
    'watch': <Object?>[],
    'properties': {
      'route': {
        'enum': ['/shop', '/paid', '/refunded', '/receipt'],
      },
    },
    'moments': {
      'shop': {
        'description': 'A shop with one order',
        'projection': {'route': '/shop'},
        'backend': {'recipe': 'shop'},
      },
      'paid': {
        'from': 'shop',
        'description': 'The order, paid',
        'projection': {'route': '/paid'},
        'backend': {'recipe': 'paid'},
      },
      'refunded': {
        'from': 'paid',
        'description': 'The paid order, refunded',
        'projection': {'route': '/refunded'},
        'backend': {'recipe': 'refunded'},
      },
      'receipt': {
        'from': 'paid',
        'description': 'The receipt of the paid order',
        'projection': {'route': '/receipt'},
      },
      ...extra,
    },
  });
  writeJson(p.join(root, 'instance.json'), {'phase': 'ready'});
  return root;
}

Map<String, Object?> instanceOf(String root) => (readJson(p.join(root, 'instance.json'))! as Map).cast();
Map<String, Object?> launchOf(String root) => (instanceOf(root)['launch']! as Map).cast();
String scopeOf(String root) => launchOf(root)['dataScope']! as String;
List<Object?> modes(BackendRecipes engine) => [for (final link in engine.lastPath) '${link['moment']} ${link['mode']}'];

void main() {
  group('linearNavigationWithoutCriteria', () {
    test('a journey that declares no criteria validates; one with criteria still needs a final one', () {
      final steps = [
        {'name': 'open', 'kind': 'tap', 'target': 'order', 'until': <Object?>[]},
        {'name': 'pay', 'kind': 'tap', 'target': 'pay', 'until': <Object?>[]},
      ];
      expect(isNavigation({'checks': <Object?>[], 'steps': steps}), isTrue);
      expect(isNavigation({'checks': <Object?>[], 'steps': <Object?>[]}), isFalse);
      validateSteps({'checks': <Object?>[], 'steps': steps});
      expect(
        () => validateSteps({
          'checks': [
            {'name': 'seen', 'kind': 'ui_equals', 'field': 'route', 'equals': '/x', 'scope': 'step'},
          ],
          'steps': steps,
        }),
        refusing('observed UI or backend criterion'),
      );
    });

    test('it walks the steps once, in order, each after the screen settles, and ends navigated', () async {
      final root = temporary('moments-navigation-');
      File(p.join(root, 'lib/app.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}');
      writeJson(p.join(root, 'moments/manifest.json'), {
        'version': 1,
        'watch': ['lib/app.dart'],
        'properties': {
          'route': {
            'enum': ['/orders', '/order', '/paid'],
          },
        },
        'moments': {
          'pay-order': {
            'description': 'From the orders to a paid order',
            'projection': {'route': '/orders'},
            'steps': [
              {'name': 'open', 'kind': 'tap', 'target': 'order', 'until': <Object?>[]},
              {'name': 'pay', 'kind': 'tap', 'target': 'pay', 'until': <Object?>[]},
            ],
          },
        },
      });
      const lease = '00000000-0000-4000-8000-000000000009';
      var route = '/orders';
      final gestures = <String>[], opened = <Object?>[];
      Map<String, Object?> observed() => {
        'client': 'client',
        'revision': 'revision',
        'projection': {'route': route},
      };
      final result = await checkMoment(
        project: root,
        name: 'pay-order',
        journey: true,
        timeout: 2000,
        poll: 5,
        settleMs: 150,
        request: (path, [data]) async {
          switch (path) {
            case '/journey/lease':
              return {'id': lease, 'phase': data!['operation'] == 'finish' ? 'idle' : 'active'};
            case '/moments/open':
              opened.add(data);
              return {
                'revision': 'revision',
                'state': {
                  'name': 'pay-order',
                  'projection': {'route': '/orders'},
                },
              };
            case '/journey/tap':
              gestures.add('${data!['target']} on $route');
              route = data['target'] == 'order' ? '/order' : '/paid';
              return {...data, 'status': 'dispatched'};
            case '/moments/look':
              return {
                'revision': 'revision',
                'state': {
                  'name': 'pay-order',
                  'projection': {'route': route},
                },
                'observed': observed(),
              };
            case '/moments/inspect':
              return {
                'moment': {'revision': 'revision'},
                'screen': {
                  'lastReported': {'matchesRevision': true, 'projection': observed()['projection']},
                },
              };
          }
          if (path.startsWith('/journey/actions')) return {'version': 1, 'receipts': <Object?>[]};
          throw StateError('unexpected $path');
        },
      );
      expect(result['status'], 'navigated', reason: '${result['reason']}');
      expect(result['exitCode'], 0);
      expect(gestures, ['order on /orders', 'pay on /order'], reason: 'once each, the second after the first settled');
      expect(opened, [
        {'name': 'pay-order', 'fresh': true, 'prepare': true, 'journeyId': lease},
      ]);
      final steps = (result['steps']! as List).cast<Map>();
      expect([for (final step in steps) step['status']], ['settled', 'settled']);
      expect([for (final step in steps) (step['projection']! as Map)['route']], ['/order', '/paid']);
      expect(result['arrived'], {
        'projection': {'route': '/paid'},
      });
      expect(result['checks'], isEmpty);
      expect(result.containsKey('verdict'), isFalse, reason: 'a navigation judges nothing');
      expect((result['ownership']! as Map)['phase'], 'idle');
      final report = (readJson(result['report']! as String)! as Map).cast<String, Object?>();
      expect(report['operation'], 'navigation');
      expect(report['status'], 'navigated');
    });
  });

  group('declaredCheckpointComposition', () {
    test("a child's recipe runs on its parent's checkpoint and its launch builds on the parent's", () async {
      final root = shop(), backend = FileBackend(p.join(root, 'db'));
      final engine = BackendRecipes(
        manifestFile: p.join(root, 'moments/manifest.json'),
        recipes: {
          'shop': backend.adapter('shop', isolated: false),
          'paid': RecipeAdapter(
            prepare: (_) async => throw StateError('a child is prepared from its parent'),
            prepareFrom: (instance, parent, {snapshot}) async {
              expect(snapshot, isNull, reason: 'a shared-database parent has no snapshot');
              expect(backend.shared, ['shop'], reason: "the parent's data is in place");
              expect((parent['inputs']! as Map)['shop.id'], isA<String>());
              return {
                'launch': {
                  'route': '/paid',
                  'inputs': {'paid.id': 'p-1'},
                },
              };
            },
            inspect: (_, _) async => {},
          ),
        },
        instance: () => instanceOf(root),
        assertAvailable: () async {},
        commit: (launch, {base, preparedMoment}) async => writeJson(p.join(root, 'instance.json'), {
          ...instanceOf(root),
          'launch': launch,
          'preparedMoment': ?preparedMoment,
        }),
      );
      expect(engine.declared('receipt'), isTrue, reason: 'it opens on its parent');
      await engine.prepare('paid');
      expect(modes(engine), ['shop root', 'paid on-parent']);
      final launch = launchOf(root);
      expect(launch['route'], '/paid');
      expect((launch['inputs']! as Map).keys.toSet(), {'shop.id', 'paid.id'});
      expect(instanceOf(root)['preparedMoment'], {
        'version': 1,
        'moment': 'paid',
        'recipe': 'paid',
        'base': null,
        'from': {'version': 1, 'moment': 'shop', 'recipe': 'shop', 'base': null},
      });
      expect(preparedRecipeMatches(instanceOf(root), 'paid', {'recipe': 'paid'}), isFalse, reason: 'not a root');
      expect(preparedMomentMatches(instanceOf(root), engine.identity('paid')), isTrue);
    });

    test('a chain whose recipes disagree on where they write, or on their base, is refused before it writes', () async {
      final root = shop(
        extra: {
          'mixed': {
            'from': 'shop',
            'description': 'A shared child of an isolated parent',
            'projection': {'route': '/paid'},
            'backend': {'recipe': 'mixed'},
          },
          'based-shop': {
            'description': 'A shop on a base',
            'projection': {'route': '/shop'},
            'backend': {'recipe': 'shop', 'base': 'one'},
          },
          'based': {
            'from': 'based-shop',
            'description': 'A child on another base',
            'projection': {'route': '/paid'},
            'backend': {'recipe': 'paid', 'base': 'other'},
          },
        },
      );
      final backend = FileBackend(p.join(root, 'db'));
      final engine = BackendRecipes(
        manifestFile: p.join(root, 'moments/manifest.json'),
        recipes: {...backend.adapters(), 'mixed': backend.adapter('mixed', isolated: false)},
        bases: {
          for (final base in ['one', 'other']) base: BaseAdapter(prepare: (_) async => null),
        },
        instance: () => instanceOf(root),
        assertAvailable: () async {},
        commit: (launch, {base, preparedMoment}) async {},
      );
      await expectLater(engine.prepare('mixed'), refusing('both prepare in a database of their own'));
      expect(backend.runs(), {'shop': 1}, reason: 'the parent ran; the child never wrote to the shared database');
      expect(backend.shared, isEmpty);
      await expectLater(engine.prepare('based'), refusing('different backend bases'));
    });

    test('the launcher opens a child: the runtime prepares it through the chain and restores its projection', () async {
      final root = shop(), backend = FileBackend(p.join(root, 'db'));
      final engine = BackendRecipes(
        manifestFile: p.join(root, 'moments/manifest.json'),
        recipes: backend.adapters(),
        instance: () => instanceOf(root),
        assertAvailable: () async {},
        commit: (launch, {base, preparedMoment}) async =>
            writeJson(p.join(root, 'instance.json'), {...instanceOf(root), 'launch': launch}),
      );
      final bridge = await Bridge.start(
        project: root,
        port: 0,
        momentsOptions: MomentsOptions(manifestFile: p.join(root, 'moments/manifest.json'), prepare: engine.prepare),
      );
      addTearDown(bridge.close);
      final opened = await call(bridge.url, bridge.token, '/moments/open', {'name': 'refunded', 'prepare': true});
      expect(opened.code, 200, reason: '${opened.value}');
      expect((opened.value['state']! as Map)['projection'], {'route': '/refunded'});
      expect(backend.scope(scopeOf(root)), ['shop', 'paid', 'refunded']);
      final receipt = await call(bridge.url, bridge.token, '/moments/open', {'name': 'receipt', 'prepare': true});
      expect(receipt.code, 200, reason: '${receipt.value}');
      expect(backend.scope(scopeOf(root)), ['shop', 'paid'], reason: 'a child without a recipe is its parent');
    });
  });

  group('parentMaterialization', () {
    BackendRecipes engineFor(String root, FileBackend backend) => BackendRecipes(
      manifestFile: p.join(root, 'moments/manifest.json'),
      recipes: backend.adapters(),
      instance: () => instanceOf(root),
      assertAvailable: () async {},
      commit: (launch, {base, preparedMoment}) async =>
          writeJson(p.join(root, 'instance.json'), {...instanceOf(root), 'launch': launch}),
    );

    test("children open from their parent's captured snapshot; the parent's recipe runs once", () async {
      final root = shop(), backend = FileBackend(p.join(root, 'db'));
      final engine = engineFor(root, backend);
      await engine.prepare('paid');
      expect(modes(engine), ['shop root', 'paid from-snapshot']);
      final first = scopeOf(root);
      expect(backend.scope(first), ['shop', 'paid']);
      await engine.prepare('paid');
      expect(modes(engine), ['shop checkpoint', 'paid from-snapshot']);
      final second = scopeOf(root);
      expect(second, isNot(first));
      expect(backend.scope(second), ['shop', 'paid']);
      expect(backend.runs(), {'shop': 1, 'paid': 2}, reason: 'materialized, not replayed from the root');
      final store = CheckpointStore(p.join(root, 'moments/.backend/checkpoints.json'));
      expect(backend.snapshot(store['shop']!['snapshot']! as String), isTrue);
    });

    test('a grandchild opens from the nearest checkpoint, even in a new process', () async {
      final root = shop(), backend = FileBackend(p.join(root, 'db'));
      await engineFor(root, backend).prepare('refunded');
      expect(backend.runs(), {'shop': 1, 'paid': 1, 'refunded': 1});
      final later = engineFor(root, FileBackend(p.join(root, 'db')));
      await later.prepare('refunded');
      expect(modes(later), ['paid checkpoint', 'refunded from-snapshot']);
      expect(backend.runs(), {'shop': 1, 'paid': 1, 'refunded': 2});
      expect(backend.scope(scopeOf(root)), ['shop', 'paid', 'refunded']);
    });

    test('a checkpoint whose recipe changed, or whose snapshot is gone, is prepared again', () async {
      final root = shop(), backend = FileBackend(p.join(root, 'db'));
      final engine = engineFor(root, backend);
      await engine.prepare('paid');
      backend.digest = 'digest-2';
      await engine.prepare('paid');
      expect(modes(engine), ['shop root', 'paid from-snapshot']);
      final store = CheckpointStore(p.join(root, 'moments/.backend/checkpoints.json'));
      File(p.join(root, 'db/snapshots/${store['shop']!['snapshot']}.json')).deleteSync();
      await engine.prepare('paid');
      expect(modes(engine), ['shop root', 'paid from-snapshot']);
      expect(backend.runs(), {'shop': 3, 'paid': 3});
    });

    test("a parent's own open captures it; its situation is frozen at that point", () async {
      final root = shop(), backend = FileBackend(p.join(root, 'db'));
      final engine = engineFor(root, backend);
      await engine.prepare('shop');
      final parent = scopeOf(root);
      File(p.join(root, 'db/scopes/$parent.json')).writeAsStringSync(jsonEncode(['shop', 'edited in the UI']));
      await engine.prepare('paid');
      expect(modes(engine), ['shop checkpoint', 'paid from-snapshot']);
      expect(backend.scope(scopeOf(root)), ['shop', 'paid']);
    });
  });

  group('recordedPreparationRecovery', () {
    late String program;
    setUpAll(() async => program = await compileProgram('test/programs/interrupted_preparation.dart'));

    Future<int> interrupt(String root, String moment, String during, String layer) async {
      writeJson(p.join(root, 'instance.json'), {
        'phase': 'ready',
        'preparation': {'moment': moment, 'stage': 'startup', 'startedAt': '2026-11-01T00:00:00Z'},
      });
      final run = await Process.run(Platform.resolvedExecutable, [program, root, moment, during, layer]);
      return run.exitCode;
    }

    test('a preparation killed inside an isolated recipe is prepared again from the recorded checkpoint', () async {
      final root = shop();
      expect(await interrupt(root, 'paid', 'paid', 'isolated'), isNot(0));
      final instance = instanceOf(root);
      expect(instance['preparation'], {
        'moment': 'paid',
        'stage': 'recipe',
        'startedAt': '2026-11-01T00:00:00Z',
        'servicesPrepared': true,
        'isolated': true,
        'transition': 'paid',
      });
      expect(validatePreparationRetry(instance, retryPreparation: false, initialMoment: 'paid', services: []), isTrue);
      final backend = FileBackend(p.join(root, 'db'));
      expect(backend.runs(), {'shop': 1, 'paid': 1});
      final recovered = engine(root, backend);
      writeJson(p.join(root, 'instance.json'), {
        ...instance,
        'preparation': {'moment': 'paid', 'stage': 'startup', 'servicesPrepared': true},
      });
      await recovered.prepare('paid');
      expect(modes(recovered), ['shop checkpoint', 'paid from-snapshot'], reason: 'the parent is not prepared again');
      expect(backend.runs(), {'shop': 1, 'paid': 2});
      expect(backend.scope(scopeOf(root)), ['shop', 'paid'], reason: 'the killed run wrote only to its own scope');
      expect(backend.shared, isEmpty);
    });

    test('a preparation killed in a shared-database recipe still waits for inspection', () async {
      final root = shop();
      expect(await interrupt(root, 'paid', 'paid', 'shared'), isNot(0));
      final instance = instanceOf(root);
      expect((instance['preparation']! as Map)['isolated'], isFalse);
      expect(FileBackend(p.join(root, 'db')).shared, ['shop', 'paid', 'paid (partial)']);
      expect(recoverablePreparation(instance, initialMoment: 'paid'), isFalse);
      expect(
        () => validatePreparationRetry(instance, retryPreparation: false, initialMoment: 'paid', services: []),
        refusing('preparation is incomplete'),
      );
    });

    test('only a preparation that stopped before writing, or inside isolated recipes, recovers on its own', () {
      Map<String, Object?> at(String stage, {bool? isolated, String moment = 'paid', String phase = 'ready'}) => {
        'phase': phase,
        'preparation': {'moment': moment, 'stage': stage, 'isolated': ?isolated},
      };
      expect(recoverablePreparation(at('startup'), initialMoment: 'paid'), isTrue);
      expect(recoverablePreparation(at('recipe', isolated: true), initialMoment: 'paid'), isTrue);
      for (final (instance, why) in [
        (at('recipe', isolated: false), 'a shared-database recipe'),
        (at('recipe'), 'a recipe of unknown isolation'),
        (at('base'), 'the shared base'),
        (at('services'), 'services (up --retry-preparation)'),
        (at('startup', moment: 'shop'), 'another Moment'),
        (at('startup', phase: 'seeding'), 'a base being seeded'),
      ]) {
        expect(recoverablePreparation(instance, initialMoment: 'paid'), isFalse, reason: why);
      }
      expect(recoverablePreparation(at('startup'), initialMoment: 'paid', journey: {'id': 'j'}), isFalse);
      expect(
        preparationTransition(preparationAt(at('startup'), 'recipe'), 'shop', false)['preparation'],
        containsPair('isolated', false),
      );
      expect(preparationAt({'phase': 'ready'}, 'recipe'), {'phase': 'ready'}, reason: 'an open after startup');
    });
  });
}
