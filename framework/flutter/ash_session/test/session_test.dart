import 'dart:async';

import 'package:ash_session/ash_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStore implements SessionStore {
  MemoryStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async {
    value = next;
  }
}

final user = SessionIdentity(
  userId: 'one',
  email: 'one@unit.test',
  expiresAt: DateTime.utc(2099),
);
AshSession session(
  MemoryStore store, {
  Dio? dio,
  Future<SessionIdentity> Function()? identify,
  Future<SignedSession> Function(String, String)? authenticate,
  Future<void> Function()? revoke,
  Future<SignedSession> Function(String, String, String)? register,
}) => AshSession(
  dio: dio ?? Dio(BaseOptions(baseUrl: 'http://unit.test')),
  store: store,
  authenticate: authenticate ?? (_, _) async => SignedSession('jwt', user),
  identify: identify ?? () async => user,
  revoke: revoke ?? () async {},
  register: register,
);
void main() {
  test(
    'old 401 cannot invalidate a newer generation even with the same bearer',
    () async {
      final store = MemoryStore();
      final dio = Dio(BaseOptions(baseUrl: 'http://unit.test'));
      final s = session(store, dio: dio);
      addTearDown(s.dispose);
      final started = Completer<void>();
      final release = Completer<void>();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            started.complete();
            await release.future;
            handler.reject(
              DioException(
                requestOptions: request,
                response: Response(requestOptions: request, statusCode: 401),
                type: DioExceptionType.badResponse,
              ),
              true,
            );
          },
        ),
      );
      await s.signIn('one', 'synthetic');
      final pending = expectLater(
        dio.get('/old'),
        throwsA(isA<DioException>()),
      );
      await started.future;
      await s.signIn('one', 'synthetic');
      release.complete();
      await pending;
      expect(s.phase.value, SessionPhase.authenticated);
      expect(s.identity.value, user);
      expect(store.value, 'jwt');
    },
  );
  test('registration persists its returned session without a second sign-in and cannot resurrect after logout', () async {
    final store = MemoryStore();
    var signIns = 0;
    final pending = Completer<SignedSession>();
    var registrations = 0;
    final s = session(
      store,
      authenticate: (_, _) async {
        signIns++;
        return SignedSession('login', user);
      },
      register: (_, _, _) async {
        registrations++;
        return registrations == 1
            ? SignedSession('registered', user)
            : pending.future;
      },
    );
    addTearDown(s.dispose);
    await s.signUp('one', 'secret', 'secret');
    expect(store.value, 'registered');
    expect(s.phase.value, SessionPhase.authenticated);
    expect(signIns, 0);
    final signingUp = s.signUp('two', 'secret', 'secret');
    await s.signOut();
    pending.complete(SignedSession('late', user));
    await signingUp;
    expect(store.value, '');
    expect(s.phase.value, SessionPhase.anonymous);
    expect(signIns, 0);
  });
  test('malformed retry headers still produce a bounded throttling error', () {
    for (final values in <List<String>>[
      [],
      ['bad'],
      ['30', '60'],
      ['-1'],
      ['999999'],
    ]) {
      final response = Response<dynamic>(
        requestOptions: RequestOptions(),
        headers: Headers.fromMap({'retry-after': values}),
      );
      final before = DateTime.now();
      final problem = SignInThrottled.fromResponse(response);
      expect(problem.retryAt.isAfter(before), isTrue);
      expect(
        problem.retryAt.difference(before).inSeconds,
        lessThanOrEqualTo(3600),
      );
    }
  });
  test('429 retains its deadline and prevents repeated authentication during cooldown', () async {
    var calls = 0;
    final s = session(
      MemoryStore(),
      authenticate: (_, _) async {
        calls++;
        final request = RequestOptions(path: '/auth/sign-in');
        throw DioException(
          requestOptions: request,
          response: Response(
            requestOptions: request,
            statusCode: 429,
            headers: Headers.fromMap({
              'retry-after': ['30'],
            }),
          ),
        );
      },
    );
    addTearDown(s.dispose);
    await expectLater(
      s.signIn('one', 'secret'),
      throwsA(isA<SignInThrottled>()),
    );
    final first = s.failure.value as SignInThrottled;
    expect(first.retryAt.isAfter(DateTime.now()), isTrue);
    await expectLater(s.signIn('one', 'secret'), throwsA(same(first)));
    expect(calls, 1);
    expect(s.phase.value, SessionPhase.anonymous);
    expect(s.identity.value, isNull);
  });
  test('restart restores a cooldown without replaying credentials or authenticating', () async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    final store = MemoryStore('!retry:${deadline.millisecondsSinceEpoch}');
    final s = session(
      store,
      identify: () async => throw StateError('no bearer'),
    );
    addTearDown(s.dispose);
    expect(await s.restore(), SessionRestoration.rejected);
    expect(s.phase.value, SessionPhase.anonymous);
    expect(
      (s.failure.value as SignInThrottled).retryAt.millisecondsSinceEpoch,
      deadline.millisecondsSinceEpoch,
    );
    expect(s.identity.value, isNull);
    store.value = '!retry:1';
    await s.restore();
    expect(s.failure.value, isNull);
    expect(s.phase.value, SessionPhase.anonymous);
  });
  test('restart validates the saved token without replaying a login', () async {
    final store = MemoryStore();
    var signIns = 0;
    final first = session(
      store,
      authenticate: (_, _) async {
        signIns++;
        return SignedSession('jwt', user);
      },
    );
    expect(await first.restore(), SessionRestoration.empty);
    await first.signIn('one', 'secret');
    first.dispose();
    final second = session(
      store,
      authenticate: (_, _) async {
        signIns++;
        throw StateError('must not sign in');
      },
    );
    addTearDown(second.dispose);
    expect(await second.restore(), SessionRestoration.authenticated);
    expect(signIns, 1);
    expect(second.identity.value, user);
  });
  test(
    'network outage retains the token and retry restores identity',
    () async {
      final store = MemoryStore('jwt');
      var offline = true;
      final s = session(
        store,
        identify: () async {
          if (offline)
            throw DioException(
              requestOptions: RequestOptions(),
              type: DioExceptionType.connectionError,
            );
          return user;
        },
      );
      addTearDown(s.dispose);
      expect(await s.restore(), SessionRestoration.unavailable);
      expect(store.value, 'jwt');
      offline = false;
      expect(await s.restore(), SessionRestoration.authenticated);
    },
  );
  test('a revoked session stays anonymous after another restart', () async {
    final store = MemoryStore('jwt');
    final dio = Dio(BaseOptions(baseUrl: 'http://unit.test'));
    final s = session(
      store,
      dio: dio,
      identify: () async {
        await dio.get('/session');
        return user;
      },
    );
    addTearDown(s.dispose);
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.reject(
          DioException(
            requestOptions: request,
            response: Response(requestOptions: request, statusCode: 401),
            type: DioExceptionType.badResponse,
          ),
          true,
        ),
      ),
    );
    expect(await s.restore(), SessionRestoration.rejected);
    expect(s.ended.value, isTrue);
    expect(store.value, '!rejected');
    final next = session(store);
    addTearDown(next.dispose);
    expect(await next.restore(), SessionRestoration.rejected);
    expect(next.ended.value, isTrue);
  });
  test('logout supersedes a pending restore and cannot be undone by its late response', () async {
    final store = MemoryStore('jwt');
    final pending = Completer<SessionIdentity>();
    final s = session(store, identify: () => pending.future);
    addTearDown(s.dispose);
    final restoring = s.restore();
    await Future<void>.delayed(Duration.zero);
    await s.signOut();
    pending.complete(user);
    await restoring;
    expect(s.phase.value, SessionPhase.anonymous);
    expect(store.value, '');
  });
  test(
    'logout supersedes a pending login before it persists credentials',
    () async {
      final store = MemoryStore();
      final pending = Completer<SignedSession>();
      final s = session(store, authenticate: (_, _) => pending.future);
      addTearDown(s.dispose);
      final login = s.signIn('one', 'secret');
      await s.signOut();
      pending.complete(SignedSession('late', user));
      await login;
      expect(store.value, '');
      expect(s.phase.value, SessionPhase.anonymous);
    },
  );
  test(
    'failed server revocation is not reported as successful logout',
    () async {
      final store = MemoryStore('jwt');
      final s = session(store, revoke: () async => throw StateError('offline'));
      addTearDown(s.dispose);
      await s.restore();
      await expectLater(s.signOut(), throwsStateError);
      expect(store.value, 'jwt');
      expect(s.phase.value, SessionPhase.authenticated);
      expect(s.failure.value, isNotNull);
    },
  );
  test(
    'bearer is restricted to its origin and rejected writes are never replayed',
    () async {
      final store = MemoryStore('jwt');
      final dio = Dio(BaseOptions(baseUrl: 'http://unit.test'));
      final s = session(store, dio: dio);
      addTearDown(s.dispose);
      await s.restore();
      var writes = 0;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.uri.host == 'outside.test') {
              expect(request.headers.containsKey('Authorization'), false);
              handler.resolve(
                Response(requestOptions: request, statusCode: 200),
              );
              return;
            }
            writes++;
            expect(request.headers['Authorization'], 'Bearer jwt');
            handler.reject(
              DioException(
                requestOptions: request,
                response: Response(requestOptions: request, statusCode: 401),
                type: DioExceptionType.badResponse,
              ),
              true,
            );
          },
        ),
      );
      await dio.get('http://outside.test/');
      await expectLater(dio.patch('/write'), throwsA(isA<DioException>()));
      expect(writes, 1);
      expect(s.phase.value, SessionPhase.anonymous);
      expect(store.value, '!rejected');
    },
  );
}
