import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String project(String sensors) {
  final root = Directory.systemTemp
      .createTempSync('mana-sense-')
      .resolveSymbolicLinksSync();
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  void write(String path, String text) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(text);
  }

  write('mana.toml', 'version = 1\n[products.shop]\nfrontend = "apps/shop"\n');
  write(
    'apps/shop/moments/manifest.json',
    jsonEncode({
      'moments': {'checkout-coupon': {}},
    }),
  );
  write('apps/shop/lib/checkout/coupon.dart', '');
  write('backend/lib/orders.ex', '');
  write('features.toml', '''
version = 1
roots = ["apps/*/lib/**"]
[features."checkout"]
paths = ["apps/shop/lib/checkout/**"]
moments = ["shop:checkout-*"]
''');
  write('sensors.toml', sensors);
  return root;
}

const ok = '["sh", "-c", "exit 0"]';
const bad = '["sh", "-c", "echo broken; exit 1"]';

void main() {
  test(
    'sensors are picked by path, feature or moment coverage, cheapest first',
    () {
      final root = project('''
version = 1
[sensor.e2e]
run = $ok
proves = "behavior"
cost = "5m"
covers = ["moment:shop:checkout-*"]
[sensor.unit]
run = $ok
proves = "logic"
cost = "2s"
covers = ["apps/shop/lib/checkout/coupon.dart"]
[sensor.feature]
run = $ok
proves = "logic"
cost = "30s"
covers = ["feature:checkout"]
[sensor.backend]
run = $ok
proves = "logic"
cost = "1m"
covers = ["backend/**"]
''');
      final sensors = Sensors.load(root);
      final plan = sensors.selectFor([
        'apps/shop/lib/checkout/coupon.dart',
      ], features: FeatureMap.load(root));
      expect([for (final (s, _) in plan) s.id], ['unit', 'feature', 'e2e']);
      expect(plan.last.$2, 'moment:shop:checkout-coupon is affected');
    },
  );

  test(
    'a failure stops the climb; the budget leaves costly sensors unresolved',
    () async {
      final root = project('''
version = 1
[sensor.cheap]
run = $bad
proves = "logic"
cost = "2s"
covers = ["**"]
[sensor.costly]
run = $ok
proves = "behavior"
cost = "5m"
covers = ["**"]
''');
      final sensors = Sensors.load(root);
      final failed = await sensors.run(sensors.selectFor(['x']));
      expect(failed['outcome'], 'fail');
      final results = (failed['results']! as List).cast<Map>();
      expect(results.first['status'], 'fail');
      expect(
        File(
          p.join(root, (results.first['evidence'] as Map)['log'] as String),
        ).readAsStringSync(),
        contains('broken'),
      );
      expect(results.last['status'], 'unresolved');

      final kept = await sensors.run(sensors.selectFor(['x']), keepGoing: true);
      expect((kept['results']! as List).cast<Map>().last['status'], 'pass');

      File(p.join(root, 'sensors.toml')).writeAsStringSync('''
version = 1
[sensor.costly]
run = $ok
proves = "behavior"
cost = "5m"
covers = ["**"]
''');
      final budgeted = await Sensors.load(root).run(
        Sensors.load(root).selectFor(['x']),
        budget: const Duration(minutes: 1),
      );
      expect(budgeted['outcome'], 'inconclusive');
      expect(budgeted['acceptanceScore'], isNull);
    },
  );

  test('a Moments sensor exiting 2 is unresolved, not failed', () async {
    final root = project('''
version = 1
[sensor.moments]
run = ["sh", "-c", "exit 2"]
proves = "behavior"
cost = "1m"
output = "moments"
covers = ["**"]
''');
    final sensors = Sensors.load(root);
    final verdict = await sensors.run(sensors.selectFor(['x']));
    expect(verdict['outcome'], 'inconclusive');
  });

  test('invalid declarations are refused', () {
    for (final body in [
      'version = 1\n[sensor.a]\nrun = []\nproves = "logic"\ncost = "1s"\ncovers = []\n',
      'version = 1\n[sensor.a]\nrun = ["x"]\nproves = "vibes"\ncost = "1s"\ncovers = []\n',
      'version = 1\n[sensor.a]\nrun = ["x"]\nproves = "logic"\ncost = "soon"\ncovers = []\n',
      'version = 1\n[sensor.A]\nrun = ["x"]\nproves = "logic"\ncost = "1s"\ncovers = []\n',
    ]) {
      expect(
        () => Sensors.load(project(body)),
        throwsA(isA<ManaFailure>()),
        reason: body,
      );
    }
  });

  test(
    'learn measures real runs, spots flaky failures and reorders by what it measured',
    () async {
      final root = project('''
version = 1
[sensor.unit]
run = $ok
proves = "logic"
cost = "1s"
covers = ["apps/**"]
[sensor.slow]
run = $ok
proves = "behavior"
cost = "5m"
covers = ["apps/**"]
''');
      void run(
        String name,
        String commit,
        List<String> paths,
        Map<String, (String, int)> results,
      ) {
        final dir = p.join(root, '.mana/sense', name);
        Directory(dir).createSync(recursive: true);
        File(
          p.join(dir, 'run.json'),
        ).writeAsStringSync(jsonEncode({'commit': commit, 'paths': paths}));
        File(p.join(dir, 'verdict.json')).writeAsStringSync(
          jsonEncode({
            'results': [
              for (final MapEntry(key: id, value: (status, ms))
                  in results.entries)
                {
                  'criterionId': id,
                  'status': status,
                  'evidence': {'durationMs': ms},
                },
            ],
          }),
        );
      }

      run(
        '1',
        'a',
        ['apps/shop/lib/x.dart'],
        {'unit': ('fail', 9000), 'slow': ('pass', 2000)},
      );
      run(
        '2',
        'a',
        ['apps/shop/lib/x.dart'],
        {'unit': ('pass', 8000), 'slow': ('pass', 1000)},
      );
      run(
        '3',
        'b',
        ['apps/shop/lib/y.dart'],
        {'unit': ('fail', 7000), 'slow': ('pass', 3000)},
      );
      run('4', 'c', [], {'unit': ('pass', 10000)});
      Directory(p.join(root, '.mana/sense/5')).createSync();

      final lock = Sensors.learn(root);
      final unit = (lock['sensors']! as Map)['unit'] as Map;
      expect(unit['runs'], 4);
      expect(unit['medianMs'], 9000);
      expect(unit['p95Ms'], 10000);
      expect(unit['failRate'], 0.5);
      expect(unit['flakyRate'], 0.25);
      expect(unit['failsWith'], [
        'apps/shop/lib/x.dart',
        'apps/shop/lib/y.dart',
      ]);
      expect(unit['catchesPerMinute'], greaterThan(0));
      expect(File(p.join(root, 'sensors.lock')).existsSync(), isTrue);

      final sensors = Sensors.load(root);
      expect([for (final s in sensors.sensors) s.id], ['slow', 'unit']);
      expect(sensors.sensors.first.cost, const Duration(milliseconds: 2000));
      expect(sensors.learned['unit']?['runs'], 4);

      final verdict = await sensors.run(
        [(sensors.named('slow'), 'requested')],
        paths: ['apps/shop/lib/z.dart'],
      );
      expect(verdict['outcome'], 'pass');
      final latest = Directory(p.join(root, '.mana/sense'))
          .listSync()
          .whereType<Directory>()
          .where((d) => RegExp(r'^\d{4}-').hasMatch(p.basename(d.path)))
          .single;
      expect(
        (jsonDecode(File(p.join(latest.path, 'run.json')).readAsStringSync())
            as Map)['paths'],
        ['apps/shop/lib/z.dart'],
      );
    },
  );
}
