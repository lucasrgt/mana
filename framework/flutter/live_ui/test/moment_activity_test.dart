import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_ui/live_ui.dart';

/// Answers each request when the test releases it.
final class _Held implements HttpClientAdapter {
  final pending = <Completer<void>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final release = Completer<void>();
    pending.add(release);
    await release.future;
    return ResponseBody.fromString('{}', 200);
  }

  @override
  void close({bool force = false}) {}
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'requests in flight reach the runner as activity, one report per change',
    () async {
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
          if (request.url.path == '/moments/activity') {
            reports.add(jsonDecode(request.body) as Map<String, dynamic>);
          }
          return http.Response('{}', 200);
        }),
      );
      final connected = controller.connect(
        Uri.parse('http://127.0.0.1:18741'),
        'local-test',
      );
      await settle();
      expect(controller.revision, 'r1');
      final adapter = _Held();
      final dio = Dio()..httpClientAdapter = adapter;
      MomentActionTrace.attach(dio, Uri.parse('http://127.0.0.1:5198'));
      final first = dio.get<Object?>('http://127.0.0.1:5198/api/a');
      final second = dio.get<Object?>('http://127.0.0.1:5198/api/b');
      await settle();
      await settle();
      expect(MomentActivity.inFlight, 2);
      expect(reports.last, {
        'revision': 'r1',
        'client': controller.clientId,
        'sequence': reports.length,
        'inFlight': 2,
      });
      adapter.pending.first.complete();
      await first;
      adapter.pending.last.complete();
      await second;
      await settle();
      expect(MomentActivity.inFlight, 0);
      expect(reports.last['inFlight'], 0);
      expect(
        [for (final report in reports) report['sequence']],
        [for (var i = 1; i <= reports.length; i++) i],
      );
      controller.dispose();
      idle.complete(http.Response('', 204));
      await connected;
    },
  );

  test('a failed request also ends its activity', () async {
    final dio = Dio()
      ..httpClientAdapter = _Failing()
      ..interceptors.clear();
    MomentActionTrace.attach(dio, Uri.parse('http://127.0.0.1:5198'));
    final before = MomentActivity.inFlight;
    await expectLater(
      dio.get<Object?>('http://127.0.0.1:5198/api/a'),
      throwsA(isA<DioException>()),
    );
    expect(MomentActivity.inFlight, before);
  });
}

final class _Failing implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'offline',
  );

  @override
  void close({bool force = false}) {}
}
