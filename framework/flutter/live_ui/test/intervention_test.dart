import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  tearDown(() => MomentIntervention.set(const []));

  Dio client() {
    final dio = Dio(BaseOptions(baseUrl: 'http://127.0.0.1:9'));
    MomentIntervention.attach(dio);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) => handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: 'real'),
        ),
      ),
    );
    return dio;
  }

  test('rules parse the AVP conditions and ignore anything else', () {
    expect(
      NetRule.parse('net:/api/*=offline')?.condition,
      NetCondition.offline,
    );
    expect(
      NetRule.parse('net:/a/**=slow:250')?.delay,
      const Duration(milliseconds: 250),
    );
    expect(NetRule.parse('net:*=api-error')?.condition, NetCondition.apiError);
    expect(NetRule.parse('fn:Pricing.total=3'), isNull);
    expect(NetRule.parse('net:/a=sometimes'), isNull);
    MomentIntervention.set(['net:/a=empty', 'nonsense']);
    expect(MomentIntervention.rules, hasLength(1));
  });

  test(
    'a matching request answers as the condition says; others go through',
    () async {
      final dio = client();
      expect((await dio.get<Object>('/api/other')).data, 'real');

      MomentIntervention.set(['net:/api/notifications/*=offline']);
      await expectLater(
        dio.get<Object>('/api/notifications/1'),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.connectionError,
          ),
        ),
      );
      expect((await dio.get<Object>('/api/notifications')).data, 'real');

      MomentIntervention.set(['net:/api/**=api-error']);
      await expectLater(
        dio.get<Object>('/api/x/y'),
        throwsA(
          isA<DioException>().having(
            (e) => e.response?.statusCode,
            'status',
            500,
          ),
        ),
      );

      MomentIntervention.set(['net:/api/list=empty']);
      expect((await dio.get<Object>('/api/list')).data, {'data': <Object>[]});

      MomentIntervention.set(['net:/api/slow=slow:30']);
      final watch = Stopwatch()..start();
      expect((await dio.get<Object>('/api/slow')).data, 'real');
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(25));
    },
  );
}
