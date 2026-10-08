import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String project() {
  final root = Directory.systemTemp
      .createTempSync('mana-memory-')
      .resolveSymbolicLinksSync();
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  void write(String path, String text) => (File(
    p.join(root, path),
  )..createSync(recursive: true)).writeAsStringSync(text);
  write('mana.toml', 'version = 1\n[products.shop]\nfrontend = "apps/shop"\n');
  write('apps/shop/lib/checkout/coupon.dart', 'v1');
  write('features.toml', '''
version = 1
roots = ["apps/*/lib/**"]
[features."checkout/coupon"]
paths = ["apps/shop/lib/checkout/**"]
''');
  write('sensors.toml', '''
version = 1
[sensor.unit]
run = ["sh", "-c", "exit 0"]
proves = "logic"
cost = "1s"
covers = ["apps/**"]
''');
  write(
    '.mana/sense/2026-10-07T10-00-00Z/verdict.json',
    jsonEncode({
      'outcome': 'pass',
      'acceptanceScore': 1.0,
      'results': [
        {'criterionId': 'unit', 'status': 'pass'},
      ],
    }),
  );
  return root;
}

void main() {
  test(
    'a note is addressed by coordinate, keeps its receipt and goes stale when the code moves',
    () {
      final root = project();
      final notebook = Notebook(root);
      final note = notebook.add(
        why:
            'Coupons apply before shipping: the provider charges shipping on the discounted total',
        about: ['feature:checkout/coupon', 'verb:order.apply_coupon'],
        receipt: '.mana/sense/2026-10-07T10-00-00Z/verdict.json',
      );
      expect(note['receipt'], {
        'path': '.mana/sense/2026-10-07T10-00-00Z/verdict.json',
        'outcome': 'pass',
        'acceptanceScore': 1.0,
        'results': ['unit:pass'],
      });
      expect(note['files'], 1);
      notebook.add(
        why: 'Tried a cap per order; refused by the host',
        about: ['verb:order.apply_coupon'],
        outcome: 'failed',
      );

      expect(
        notebook.about('verb:order.apply_coupon').map((n) => n['outcome']),
        ['failed', 'decided'],
      );
      expect(notebook.about('feature:checkout').single['stale'], isFalse);
      expect(
        notebook.find(note['id']! as String)?['why'],
        startsWith('Coupons apply'),
      );

      File(
        p.join(root, 'apps/shop/lib/checkout/coupon.dart'),
      ).writeAsStringSync('v2');
      expect(notebook.about('feature:checkout/coupon').single['stale'], isTrue);

      expect(
        () => notebook.add(why: '', about: ['feature:x']),
        throwsA(isA<ManaFailure>()),
      );
      expect(
        () => notebook.add(why: 'w', about: ['somewhere']),
        throwsA(isA<ManaFailure>()),
      );
      expect(
        () => notebook.add(why: 'w', about: ['feature:x'], outcome: 'maybe'),
        throwsA(isA<ManaFailure>()),
      );
      expect(
        () =>
            notebook.add(why: 'w', about: ['feature:x'], receipt: 'nope.json'),
        throwsA(isA<ManaFailure>()),
      );
    },
  );

  test(
    'an intent freezes on approval, refuses later edits and checks into a verdict',
    () async {
      final root = project();
      final file = File(p.join(root, 'intents/coupon-cap.toml'))
        ..createSync(recursive: true);
      file.writeAsStringSync('''
ask = "A coupon never takes more than half the order"
feature = "checkout/coupon"
[[situation]]
moment = "shop:checkout-coupon"
expect = "a 90% coupon shows half off"
[[criterion]]
id = "moment"
moment = "shop:checkout-coupon"
[[criterion]]
id = "unit"
sensor = "unit"
''');
      final intents = Intents(root);
      expect(intents.list().single['status'], 'proposed');
      await expectLater(
        intents.check('coupon-cap', moment: (_, _) async => 0),
        throwsA(isA<ManaFailure>()),
      );

      final approved = intents.approve('coupon-cap', by: 'product');
      expect(approved['status'], 'approved');
      expect(
        () => intents.approve('coupon-cap', by: 'product'),
        throwsA(isA<ManaFailure>()),
      );
      expect(
        Notebook(root).about('moment:shop:checkout-coupon').single['why'],
        contains('approved by product'),
      );

      final ran = <String>[];
      final verdict = await intents.check(
        'coupon-cap',
        moment: (app, name) async {
          ran.add('$app:$name');
          return 0;
        },
      );
      expect(ran, ['shop:checkout-coupon']);
      expect(verdict['outcome'], 'pass');
      expect((verdict['results']! as List).map((r) => (r as Map)['status']), [
        'pass',
        'pass',
      ]);
      expect(
        (await intents.check(
          'coupon-cap',
          moment: (_, _) async => 1,
        ))['outcome'],
        'fail',
      );

      file.writeAsStringSync(
        file.readAsStringSync().replaceAll(
          'sensor = "unit"',
          'moment = "shop:other"',
        ),
      );
      await expectLater(
        intents.check('coupon-cap', moment: (_, _) async => 0),
        throwsA(isA<ManaFailure>()),
      );

      File(p.join(root, 'intents/broken.toml')).writeAsStringSync('ask = "x"');
      expect(() => intents.read('broken'), throwsA(isA<ManaFailure>()));
      expect(() => intents.read('missing'), throwsA(isA<ManaFailure>()));
    },
  );

  test('a rule that cites a missing note is reported', () {
    final root = project();
    final note = Notebook(
      root,
    ).add(why: 'Refunds wait for the host', about: ['verb:booking.cancel']);
    Map contract(String id) => {
      'components': {
        'schemas': {
          'booking': {
            'x-mana-verbs': [
              {'name': 'cancel', 'because': id},
              {'name': 'accept'},
            ],
          },
        },
      },
    };
    expect(
      unexplainedRules(contract(note['id']! as String), Notebook(root)),
      isEmpty,
    );
    expect(unexplainedRules(contract('gone'), Notebook(root)), [
      'booking.cancel → gone',
    ]);
    expect(unexplainedRules(null, Notebook(root)), isEmpty);
  });
}
