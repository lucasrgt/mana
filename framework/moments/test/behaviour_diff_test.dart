import 'dart:io';
import 'dart:math';

import 'package:mana/runtime.dart' show uuidV4;
import 'package:moments/src/behaviour_diff.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/protocol.dart';
import 'package:moments/src/situations.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// `Moments.Recipes` of a shop at one version: each recipe prepares an order
/// in a data scope of its own, with a generated customer name (different on
/// every evaluation, as real fixtures are) and the total its price rule gives.
final class Shop {
  Shop({this.coupon = 10, this.digest = 'v1', this.cashierScreen = false});

  final int coupon;
  final String digest;
  final bool cashierScreen;
  final _random = Random();
  final _scopes = <String, Map<String, Object?>>{};

  int total(String recipe) => recipe == 'coupon' ? 10000 * (100 - coupon) ~/ 100 : 10000;

  Future<Map<String, Object?>> call(String recipe, String operation, Map<String, Object?> body) async {
    final scope = (body['launch'] as Map?)?['dataScope'] as String?;
    switch (operation) {
      case 'prepare':
        if (recipe == 'shared') return {'route': '/'};
        final id = uuidV4();
        _scopes[id] = {'recipe': recipe, 'customer': 'Rosa ${_random.nextInt(1 << 30)}', 'order': uuidV4()};
        return {'route': '/orders', 'dataScope': id};
      case 'project':
        final situation = _scopes[scope]!, recipe = situation['recipe']! as String;
        return {
          'recipe': digest,
          'tables': {'orders': 1, 'customers': 1, if (cashierScreen && recipe == 'coupon') 'audits': 1},
          'history': [
            {
              'log': 'Shop.History',
              'subject': 'order:${situation['order']}',
              'action': 'place',
              'verb': 'place',
              'actorKind': 'customer',
              'outcome': 'done',
              'before': <String, Object?>{},
              'after': {
                'total_cents': total(recipe),
                'customer': situation['customer'],
                'placed_at': DateTime.now().toUtc().toIso8601String(),
              },
            },
          ],
        };
      case 'observe':
        final situation = _scopes[scope]!, recipe = situation['recipe']! as String;
        return {'total': 'R\$ ${total(recipe) ~/ 100}', 'customer': situation['customer'], 'order': situation['order']};
    }
    throw StateError('unexpected $operation');
  }
}

Map<String, Object?> scene(String recipe) => {
  'description': recipe,
  'backend': {'recipe': recipe},
};

/// An app declaring [moments] (name → recipe), under [root].
String app(String root, Map<String, String> moments) {
  final project = p.join(root, 'app');
  writeJson(p.join(project, 'moments/manifest.json'), {
    'version': 3,
    'protocol': protocol,
    'watch': <Object?>[],
    'properties': <String, Object?>{},
    'moments': {for (final MapEntry(:key, :value) in moments.entries) key: scene(value)},
  });
  return project;
}

const shopMoments = {'checkout': 'plain', 'checkout-with-coupon': 'coupon', 'browse': 'shared'};

Future<Map<String, Evaluation>> evaluated(String project, Shop shop, [List<String>? names]) => evaluateMoments(
  Situations(project: project, call: shop.call, backendVersion: () => shop.digest),
  names ?? shopMoments.keys.toList(),
);

String git(String root, List<String> args) {
  final result = Process.runSync('git', [
    '-c',
    'user.name=t',
    '-c',
    'user.email=t@t',
    '-c',
    'protocol.file.allow=always',
    '-C',
    root,
    ...args,
  ]);
  if (result.exitCode != 0) throw StateError('git $args: ${result.stderr}');
  return '${result.stdout}'.trim();
}

void main() {
  group('compareVersions', () {
    test(
      'a changed price rule names the Moment, the field and both values; an unchanged Moment has no entry',
      () async {
        final project = app(temporary('moments-diff-'), shopMoments);
        final report = compareVersions(
          shopMoments.keys.toList(),
          await evaluated(project, Shop()),
          await evaluated(project, Shop(coupon: 19)),
        );
        expect(report['compared'], 2);
        expect((report['moments']! as Map).keys, ['checkout-with-coupon']);
        final entry = (report['moments']! as Map)['checkout-with-coupon']! as Map;
        expect(entry['redefined'], false);
        expect(entry['recipe'], 'coupon');
        expect(entry['projections'], {
          'history': [
            {'entry': 'order:<id:1> place (place)', 'field': 'after.total_cents', 'base': 9000, 'head': 8100},
          ],
          'observed': [
            {'field': 'total', 'base': r'R$ 90', 'head': r'R$ 81'},
          ],
        });
        expect(report['notCompared'], [
          {
            'name': 'browse',
            'reason':
                'prepares on the shared database; fork, diff and trace need its recipe declared with data_scope: true',
          },
        ]);
      },
    );

    test('what differs between two evaluations of one version is unreproducible, not a change', () async {
      final project = app(temporary('moments-diff-'), shopMoments);
      final report = compareVersions(
        shopMoments.keys.toList(),
        await evaluated(project, Shop()),
        await evaluated(project, Shop()),
      );
      expect(report['moments'], isEmpty);
      expect((report['unreproducible']! as Map)['checkout'], [
        'history order:<id:1> place (place) · after.customer',
        'observed customer',
      ]);
    });

    test('a new table, a recipe that changed and Moments that came or went are reported as such', () async {
      final root = temporary('moments-diff-');
      final before = app(p.join(root, 'before'), {'checkout-with-coupon': 'coupon', 'gone': 'plain'});
      final after = app(p.join(root, 'after'), {'checkout-with-coupon': 'coupon', 'fresh': 'plain'});
      final names = ['checkout-with-coupon', 'fresh', 'gone'];
      final report = compareVersions(
        names,
        await evaluated(before, Shop(), names),
        await evaluated(after, Shop(digest: 'v2', cashierScreen: true), names),
      );
      final entry = (report['moments']! as Map)['checkout-with-coupon']! as Map;
      expect(entry['redefined'], true);
      expect((entry['projections']! as Map)['rows'], [
        {'field': 'audits', 'base': 0, 'head': 1},
      ]);
      expect(report['added'], ['fresh']);
      expect(report['removed'], ['gone']);
    });

    test('Moments sharing a recipe share one evaluation', () async {
      final project = app(temporary('moments-diff-'), {'a': 'plain', 'b': 'plain', 'c': 'coupon'});
      var prepares = 0;
      final shop = Shop();
      final results = await evaluateMoments(
        Situations(
          project: project,
          call: (recipe, operation, body) {
            if (operation == 'prepare') prepares++;
            return shop.call(recipe, operation, body);
          },
          backendVersion: () => 'v1',
        ),
        ['a', 'b', 'c', 'unknown'],
      );
      expect(results.keys, ['a', 'b', 'c']);
      expect(identical(results['a'], results['b']), isTrue);
      expect(prepares, 4, reason: 'two evaluations per recipe');
    });
  });

  group('screen layers', () {
    /// `suite --headless` with observations, at a version whose coupon gives
    /// [coupon]%: every run shows a fresh fixture name and order id, as real
    /// journeys do; the head also offers removing the coupon.
    Future<Map<String, Object?>> Function(List<String>) journeys(int coupon, {bool head = false}) =>
        (names) async => {
          'results': [
            for (final name in names)
              if (name == 'kiosk')
                {'name': name, 'status': 'skipped', 'reason': 'declared for web only'}
              else
                {
                  'name': name,
                  'status': 'passed',
                  'observation': {
                    'projection': {
                      'destination': '/orders',
                      'total': name == 'checkout-with-coupon' ? 'R\$ ${100 - coupon}' : r'R$ 100',
                      'fixture': 'Rosa ${Random().nextInt(1 << 30)}',
                    },
                    'offered': [
                      'verb:order.pay:${uuidV4()}',
                      if (head && name == 'checkout-with-coupon') 'verb:order.remove_coupon:${uuidV4()}',
                    ],
                  },
                },
          ],
        };

    test('a journey\'s last screen and offered verbs are compared, without what differs between two runs', () async {
      final moments = {...shopMoments, 'kiosk': 'shared'};
      final project = app(temporary('moments-diff-'), moments);
      final names = moments.keys.toList();
      final base = await observeScreens(project, names, await evaluated(project, Shop(), names), suite: journeys(10));
      final head = await observeScreens(
        project,
        names,
        await evaluated(project, Shop(coupon: 19), names),
        suite: journeys(19, head: true),
      );
      final report = compareVersions(names, base, head);
      final entry = (report['moments']! as Map)['checkout-with-coupon']! as Map;
      expect((entry['projections']! as Map)['screen'], [
        {'field': 'total', 'base': r'R$ 90', 'head': r'R$ 81'},
      ]);
      expect((entry['projections']! as Map)['offered'], [
        {'field': 'verb:order.remove_coupon:<id:2>', 'base': null, 'head': true},
      ]);
      expect((report['moments']! as Map).keys, ['checkout-with-coupon'], reason: 'checkout and browse do the same');
      expect((report['unreproducible']! as Map)['browse'], ['screen fixture']);
      expect(report['compared'], 3, reason: 'browse, on the shared database, is still compared by its screen');
      expect(report['notCompared'], [
        {
          'name': 'kiosk',
          'reason':
              'prepares on the shared database; fork, diff and trace need its recipe declared with data_scope: true; declared for web only',
        },
      ]);
      expect(report['layersNotCompared'], [
        {
          'name': 'browse',
          'layers': ['rows', 'history', 'observed'],
          'reason':
              'prepares on the shared database; fork, diff and trace need its recipe declared with data_scope: true',
        },
      ]);
      final markdown = behaviourMarkdown({
        'base': {'ref': 'main', 'commit': 'abcdef0123'},
        ...report,
      });
      expect(markdown, contains('**Screen**\n- `total` went from `"R\$ 90"` to `"R\$ 81"`'));
      expect(markdown, contains('**Offered verbs**\n- `verb:order.remove_coupon:<id:2>` is offered now'));
      expect(markdown, contains('- `browse`: rows, history, observed: prepares on the shared database'));
    });

    test('a run that cannot start leaves the screen layers out, with its reason', () async {
      final project = app(temporary('moments-diff-'), shopMoments);
      final names = shopMoments.keys.toList();
      final result = await observeScreens(
        project,
        names,
        await evaluated(project, Shop(), names),
        suite: (_) => throw const MomentsError('moments/backend.json must declare headless'),
      );
      expect(result['checkout']!.screens, isEmpty);
      expect(result['checkout']!.screenReason, 'moments/backend.json must declare headless');
      expect(result['checkout']!.data, hasLength(2));
    });
  });

  test('the Markdown says what the system does differently, by Moment, and nothing of unchanged Moments', () async {
    final project = app(temporary('moments-diff-'), {...shopMoments, 'checkout-again': 'coupon'});
    final names = [...shopMoments.keys, 'checkout-again'];
    final markdown = behaviourMarkdown({
      'base': {'ref': 'main', 'commit': 'abcdef0123'},
      'head': {'label': 'the working tree'},
      ...compareVersions(
        names,
        await evaluated(project, Shop(), names),
        await evaluated(project, Shop(coupon: 19), names),
      ),
    });
    expect(
      markdown,
      contains('3 Moments compared between `main` (abcdef0) and the working tree: 2 behave differently.'),
    );
    expect(markdown, contains('### `checkout-with-coupon`, `checkout-again`'));
    expect(markdown, contains('- `order:<id:1> place (place)`: `after.total_cents` went from `9000` to `8100`'));
    expect(markdown, contains(r'- `total` went from `"R$ 90"` to `"R$ 81"`'));
    expect(markdown, isNot(contains('### `checkout`\n')));
    expect(markdown, contains('- `browse`: prepares on the shared database'));
  });

  test(
    'diff --base checks the base out with its submodules, evaluates both versions and writes both reports',
    () async {
      final root = temporary('moments-diff-repo-');
      final engine = p.join(temporary('moments-diff-engine-'), 'engine');
      Directory(engine).createSync(recursive: true);
      git(engine, ['init', '-q', '-b', 'main']);
      File(p.join(engine, 'coupon')).writeAsStringSync('10');
      git(engine, ['add', '.']);
      git(engine, ['commit', '-q', '-m', 'ten percent']);
      git(root, ['init', '-q', '-b', 'main']);
      app(root, shopMoments);
      git(root, ['submodule', 'add', '-q', engine, 'engine']);
      git(root, ['add', '.']);
      git(root, ['commit', '-q', '-m', 'base']);
      final base = git(root, ['rev-parse', 'HEAD']);
      // The pull request: the engine's price rule gives 19% now.
      File(p.join(root, 'engine/coupon')).writeAsStringSync('19');
      git(p.join(root, 'engine'), ['commit', '-q', '-am', 'nineteen percent']);
      git(root, ['commit', '-q', '-am', 'bump the engine']);

      final seen = <String, String>{};
      final out = p.join(temporary('moments-diff-out-'), 'report');
      final report = await behaviourDiff(
        project: p.join(root, 'app'),
        base: base,
        out: out,
        evaluate: (project, names, {required discard, required log}) {
          final coupon = File(p.join(project, '../engine/coupon')).readAsStringSync();
          seen[discard ? 'base' : 'head'] = coupon;
          return evaluated(project, Shop(coupon: int.parse(coupon)), names);
        },
      );
      expect(seen, {'base': '10', 'head': '19'}, reason: 'the base checkout has the submodule at its recorded commit');
      expect((report['moments']! as Map).keys, ['checkout-with-coupon']);
      expect((report['selection']! as Map)['moments'], shopMoments.keys);
      expect(readJson(p.join(out, 'behaviour-diff.json')), containsPair('changed', 1));
      expect(File(p.join(out, 'behaviour-diff.md')).readAsStringSync(), contains('went from `9000` to `8100`'));
      expect(git(root, ['worktree', 'list']).split('\n'), hasLength(1), reason: 'the base checkout is removed');
      expect(git(p.join(root, 'engine'), ['worktree', 'list']).split('\n'), hasLength(1));
    },
  );

  group('parse', () {
    test('diff --base takes --affected and --out, and no situations', () {
      final options = parseArgs(['diff', '--base', 'origin/main', '--affected', '--out', 'report']);
      expect([options.command, options.base, options.affected, options.out], ['diff', 'origin/main', true, 'report']);
      for (final args in [
        ['diff', '--base', 'main', 'checkout'],
        ['diff', 'a', 'b', '--out', 'x'],
        ['diff', 'a', 'b', '--affected'],
        ['suite', '--out', 'x'],
        ['diff', '--base', 'main', '--fresh'],
      ]) {
        expect(() => parseArgs(args), throwsA(anything), reason: '$args');
      }
    });
  });
}
