import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_ui/live_ui.dart';
import 'package:live_ui/src/moment_gestures.dart';
import 'package:mana_primitives/mana_primitives.dart';

void main() {
  testWidgets(
    'a verb key with no record taps the first record offering it; an id picks one',
    (tester) async {
      final taps = <String>[];
      Widget row(String key) => ElevatedButton(
        key: ValueKey(key),
        onPressed: () => taps.add(key),
        child: Text(key),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                row('verb:booking.pay:1'),
                row('verb:booking.pay:2'),
                row('verb:booking.payout'),
                SizedBox(child: row('plain')),
                SizedBox(child: row('plain')),
              ],
            ),
          ),
        ),
      );
      final gestures = MomentGestures();
      Future<String?> tap(String key) => tester.runAsync(
        () => gestures.tap(key, current: () => true, patience: Duration.zero),
      );
      expect(await tap('verb:booking.pay'), 'dispatched');
      expect(await tap('verb:booking.pay:2'), 'dispatched');
      expect(await tap('verb:booking.cancel'), 'not-found');
      expect(await tap('plain'), 'ambiguous');
      expect(taps, ['verb:booking.pay:1', 'verb:booking.pay:2']);
    },
  );

  test('a gesture trace names its verb on every receipt it forwards', () async {
    const gesture = '10000000-0000-4000-8000-000000000001';
    final receipt = base64Url.encode(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'gesture': gesture,
          'request': 'a' * 32,
          'truncated': false,
          'scope': 'request-actions-only',
          'coverage': 'not-established',
          'actions': [],
        }),
      ),
    );
    final records = <Map<String, dynamic>>[];
    await MomentActionTrace.run(
      gesture,
      (value) async => records.add(value),
      () async {
        await MomentActionTrace.current!.record(receipt);
        MomentActionTrace.current!.verb = 'booking.pay:42';
        await MomentActionTrace.current!.record(receipt);
      },
      verb: 'booking.pay',
    );
    expect(records.map((r) => r['verb']), ['booking.pay', 'booking.pay:42']);
  });

  testWidgets(
    'the screen report carries what its controls offer, and goes again when that changes',
    (tester) async {
      MomentAffordances.enable();
      addTearDown(MomentAffordances.disable);
      final reports = <Map<String, dynamic>>[];
      final idle = Completer<http.Response>();
      var polls = 0;
      final controller = MomentController(
        navigate: (_) {},
        client: MockClient((request) async {
          if (request.method == 'GET') {
            if (++polls > 1) return idle.future;
            return http.Response(
              jsonEncode({
                'revision': 'r1',
                'state': {
                  'name': 'pay',
                  'projection': {'route': '/'},
                },
              }),
              200,
            );
          }
          reports.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }),
      );
      final connected = controller.connect(
        Uri.parse('http://127.0.0.1:18741'),
        'local-test',
      );
      await tester.pump();
      expect(controller.revision, 'r1');
      final withdraw = MomentAffordances.offer('booking.cancel:1');
      await tester.pump();
      expect(reports, isEmpty, reason: 'Nothing to repeat before a report');
      await controller.observe({'route': '/'});
      expect(reports.single['offered'], ['booking.cancel:1']);
      MomentAffordances.offer('booking.pay:1');
      withdraw();
      await tester.pump();
      await tester.pump();
      expect(reports, hasLength(2));
      expect(reports.last['projection'], {'route': '/'});
      expect(reports.last['offered'], ['booking.pay:1']);
      controller.dispose();
      idle.complete(http.Response('', 204));
      await tester.pump();
      await connected;
    },
  );
}
