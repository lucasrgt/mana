import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'examples are grouped by the Moment their gesture ran in, with what changed',
    () {
      final root = Directory.systemTemp.createTempSync('mana-examples-').path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      void write(String path, String text) => (File(
        p.join(root, path),
      )..createSync(recursive: true)).writeAsStringSync(text);
      final report = p.join(root, 'apps/shop/moments/.proofs/r.json');
      write(
        'apps/shop/moments/.proofs/r.json',
        jsonEncode({
          'actions': {
            'receipts': [
              {'gesture': 'g1'},
            ],
          },
        }),
      );
      write(
        'apps/shop/moments/.suite/run-1/summary.json',
        jsonEncode({
          'results': [
            {'name': 'checkout-coupon', 'report': report},
          ],
        }),
      );
      String call(String gesture, String at, String result) => jsonEncode({
        'function': 'Shop.Pricing.total/2',
        'gesture': gesture,
        'at': at,
        'args': ['[1, 2]', '%{rate: 10}'],
        'result': result,
      });
      write(
        '.mana/examples/Shop.Pricing.total.jsonl',
        [
          call('g1', '2026-10-07T10:00:00Z', '30'),
          call('g1', '2026-10-07T11:00:00Z', '27'),
          call(
            'g9',
            '2026-10-07T09:00:00Z',
            'id 6f1c2a0e-1b2c-4d3e-8f90-123456789abc',
          ),
          call(
            'g9',
            '2026-10-07T09:30:00Z',
            'id 7a1c2a0e-1b2c-4d3e-8f90-123456789abc',
          ),
          'not json',
        ].join('\n'),
      );

      final value = liveExamples(root);
      final total =
          ((value['functions']! as Map)['Shop.Pricing.total/2']! as List)
              .cast<Map>();
      expect(total.first, {
        'moment': 'shop:checkout-coupon',
        'calls': 2,
        'args': ['[1, 2]', '%{rate: 10}'],
        'result': '27',
        'at': '2026-10-07T11:00:00Z',
        'previous': '30',
      });
      expect(total.last['moment'], 'gesture:g9');
      expect(total.last.containsKey('previous'), isFalse);
      expect(
        (liveExamples(root, function: 'Other')['functions']! as Map),
        isEmpty,
      );
      expect(gestureMoments(p.join(root, 'nowhere')), isEmpty);
    },
  );
}
