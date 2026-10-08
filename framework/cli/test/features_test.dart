import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String project() {
  final root = Directory.systemTemp
      .createTempSync('mana-features-')
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
      'moments': {'checkout-coupon': {}, 'checkout-empty': {}, 'sign-in': {}},
    }),
  );
  write('apps/shop/lib/checkout/coupon.dart', '');
  write('apps/shop/lib/checkout/cart.dart', '');
  write('apps/shop/lib/auth/sign_in.dart', '');
  write('backend/lib/shop/orders.ex', '');
  write('features.toml', '''
version = 1
roots = ["apps/*/lib/**", "backend/lib/**"]

[features."checkout/coupon"]
description = "Coupons at checkout."
paths = ["apps/shop/lib/checkout/coupon.dart", "backend/lib/shop/{orders,coupons}.ex"]
moments = ["shop:checkout-coupon"]

[features."checkout"]
description = "The cart."
paths = ["apps/shop/lib/checkout/**"]
moments = ["*:checkout-*"]
''');
  return root;
}

void main() {
  test('globs cross directories only with ** and support alternation', () {
    expect(
      globPattern('apps/*/lib/**').hasMatch('apps/shop/lib/a/b.dart'),
      isTrue,
    );
    expect(
      globPattern('apps/*/lib/**').hasMatch('apps/shop/test/a.dart'),
      isFalse,
    );
    expect(globPattern('lib/*.dart').hasMatch('lib/a/b.dart'), isFalse);
    expect(globPattern('lib/{a,b}.ex').hasMatch('lib/b.ex'), isTrue);
    expect(globPattern('lib/**/x.ex').hasMatch('lib/x.ex'), isTrue);
    expect(() => globPattern('lib/{a,b.ex'), throwsA(isA<ManaFailure>()));
  });

  test(
    'owners, descriptions and moments resolve against the declared catalog',
    () {
      final map = FeatureMap.load(project());
      expect(map.owners('apps/shop/lib/checkout/coupon.dart'), [
        'checkout/coupon',
        'checkout',
      ]);
      final coupon = map.describe(map.named('checkout/coupon'));
      expect(coupon['address'], 'feature:checkout/coupon');
      expect(coupon['files'], [
        'apps/shop/lib/checkout/coupon.dart',
        'backend/lib/shop/orders.ex',
      ]);
      expect(coupon['moments'], ['shop:checkout-coupon']);
      expect(map.moments(map.named('checkout')), [
        'shop:checkout-coupon',
        'shop:checkout-empty',
      ]);
    },
  );

  test(
    'check fails on unowned files, globs without files and unknown moments',
    () {
      final root = project();
      final map = FeatureMap.load(root);
      final report = map.check();
      expect(report['status'], 'failed');
      expect(report['unowned'], ['apps/shop/lib/auth/sign_in.dart']);
      expect(report['stalePaths'], isEmpty);
      File(p.join(root, 'features.toml')).writeAsStringSync('''
version = 1
roots = ["apps/*/lib/**"]
[features."everything"]
paths = ["apps/*/lib/**", "apps/gone/**"]
moments = ["shop:missing"]
''');
      final stale = FeatureMap.load(root).check();
      expect(stale['unowned'], isEmpty);
      expect(stale['stalePaths'], ['everything: apps/gone/**']);
      expect(stale['staleMoments'], ['everything: shop:missing']);
    },
  );

  test('invalid declarations are refused before use', () {
    final root = project();
    for (final body in [
      'version = 2\n[features."a"]\npaths = []\n',
      'version = 1\n',
      'version = 1\n[features."Bad Name"]\npaths = []\n',
      'version = 1\n[features."a"]\nmoments = ["no-app"]\n',
    ]) {
      File(p.join(root, 'features.toml')).writeAsStringSync(body);
      expect(
        () => FeatureMap.load(root),
        throwsA(isA<ManaFailure>()),
        reason: body,
      );
    }
  });

  test(
    'coverage crosses features, verbs, moments and sensors and names the gaps',
    () {
      final map = FeatureMap.load(project());
      final value = map.coverage(
        [
          {
            'components': {
              'schemas': {
                'order': {
                  'x-mana-verbs': [
                    {'name': 'apply_coupon', 'feature': 'checkout/coupon'},
                    {'name': 'refund', 'feature': 'payments'},
                    {'name': 'archive'},
                  ],
                },
                'plain': {'type': 'object'},
              },
            },
          },
          null,
        ],
        sensorCovers: {
          'shop-test': ['feature:checkout/coupon', 'apps/shop/**'],
          'other': ['backend/**'],
        },
      );
      final rows = (value['features']! as List).cast<Map>();
      expect(rows.first, {
        'feature': 'checkout/coupon',
        'verbs': ['order.apply_coupon'],
        'moments': ['shop:checkout-coupon'],
        'sensors': ['shop-test'],
      });
      expect(value['status'], 'gaps');
      expect(value['featuresWithoutVerbs'], ['checkout']);
      expect(value['verbsWithUnknownFeature'], [
        'order.refund → feature:payments',
      ]);
      expect(value['verbsWithoutFeature'], ['order.archive']);
      expect(value['unexercisedVerbs'], isEmpty);
      expect(
        (map.coverage(const [], only: 'checkout')['features']! as List).length,
        1,
      );
    },
  );
}
