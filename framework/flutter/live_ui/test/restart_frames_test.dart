import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_ui/live_ui.dart';
import 'package:live_ui/src/restart_frames.dart';

void main() {
  testWidgets('pause prevents old frame delivery; resume restores callbacks', (
    tester,
  ) async {
    final dispatcher = PlatformDispatcher.instance;
    final begin = dispatcher.onBeginFrame;
    final draw = dispatcher.onDrawFrame;
    final frames = RestartFrames();
    addTearDown(frames.dispose);
    frames.pause('restart', const Duration(seconds: 1));
    expect(dispatcher.onBeginFrame, isNot(same(begin)));
    expect(dispatcher.onDrawFrame, isNot(same(draw)));
    frames.pause('restart', const Duration(seconds: 1));
    frames.resume('stale');
    expect(dispatcher.onDrawFrame, isNot(same(draw)));
    frames.resume('restart');
    expect(dispatcher.onBeginFrame, same(begin));
    expect(dispatcher.onDrawFrame, same(draw));
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('Recovered'),
      ),
    );
    expect(find.text('Recovered'), findsOneWidget);
  });

  testWidgets('lost supervisor cannot leave rendering paused indefinitely', (
    tester,
  ) async {
    final dispatcher = PlatformDispatcher.instance;
    final draw = dispatcher.onDrawFrame;
    final frames = RestartFrames();
    addTearDown(frames.dispose);
    frames.pause('lost', const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 101));
    expect(dispatcher.onDrawFrame, same(draw));
  });

  testWidgets(
    'a rejected handoff releases rendering and does not navigate or capture a draft',
    (tester) async {
      final dispatcher = PlatformDispatcher.instance;
      final draw = dispatcher.onDrawFrame;
      final acknowledged = Completer<void>();
      var requests = 0;
      final controller = MomentController(
        navigate: (_) => fail('No navigation expected'),
        client: MockClient((request) async {
          requests++;
          if (request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'restart': {
                  'id': 'attempt',
                  'phase': 'pause',
                  'leaseMs': 90000,
                },
              }),
              200,
            );
          }
          expect(request.url.path, '/moments/restart-ack');
          expect(jsonDecode(request.body)['phase'], 'paused');
          expect(dispatcher.onDrawFrame, isNot(same(draw)));
          acknowledged.complete();
          return http.Response('{}', 409);
        }),
      );
      final connected = controller.connect(
        Uri.parse('http://127.0.0.1:18741'),
        'local-test',
      );
      await acknowledged.future;
      await tester.pump();
      expect(dispatcher.onDrawFrame, same(draw));
      controller.dispose();
      await tester.pump(const Duration(seconds: 1));
      await connected;
      expect(requests, 2);
    },
  );
}
