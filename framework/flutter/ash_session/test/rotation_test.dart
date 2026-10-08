import 'dart:convert';

import 'package:ash_session/ash_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class MemoryStore implements SessionStore {
  MemoryStore([this.value]);
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String next) async => value = next;
}

String jwt(Duration validFor, String id) {
  String part(Object value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
  final exp = DateTime.now().toUtc().add(validFor).millisecondsSinceEpoch ~/ 1000;
  return '${part({'alg': 'none'})}.${part({'exp': exp, 'jti': id})}.sig';
}

final user = SessionIdentity(userId: 'one', email: 'one@unit.test', expiresAt: DateTime.utc(2099));

void main() {
  late List<String> bearers;
  late Dio dio;

  setUp(() {
    bearers = [];
    dio = Dio(BaseOptions(baseUrl: 'http://unit.test'));
    dio.httpClientAdapter = _Recorder((options) => bearers.add('${options.headers['Authorization']}'));
  });

  AshSession rotating(MemoryStore store, Future<RotatedSession> Function(String?) rotate, {Future<SignedSession> Function(String, String)? authenticate}) =>
      AshSession(
        dio: dio,
        store: store,
        authenticate: authenticate ?? (_, _) async => SignedSession(jwt(const Duration(minutes: 15), 'a1'), user, refreshToken: 'r1'),
        identify: () async => user,
        revoke: () async {},
        rotate: rotate,
      );

  test('sign-in keeps the refresh token, not the access token', () async {
    final store = MemoryStore();
    final s = rotating(store, (_) async => throw StateError('no rotation expected'));
    addTearDown(s.dispose);
    await s.signIn('one', 'secret');
    expect(store.value, 'r1');
    await dio.get('/me');
    expect(bearers.single, startsWith('Bearer '));
  });

  test('an expiring access token is renewed once before concurrent requests', () async {
    final store = MemoryStore();
    final seen = <String?>[];
    final s = rotating(
      store,
      (refresh) async {
        seen.add(refresh);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return RotatedSession(jwt(const Duration(minutes: 15), 'a2'), refreshToken: 'r2');
      },
      authenticate: (_, _) async => SignedSession(jwt(const Duration(seconds: 30), 'a1'), user, refreshToken: 'r1'),
    );
    addTearDown(s.dispose);
    await s.signIn('one', 'secret');
    final first = bearers.length;
    await Future.wait([dio.get('/a'), dio.get('/b'), dio.get('/c')]);
    expect(seen, ['r1']);
    expect(store.value, 'r2');
    expect(bearers.skip(first).toSet(), hasLength(1));
    expect(bearers.last, contains(jwt(const Duration(minutes: 15), 'a2').split('.')[0]));
  });

  test('restore rotates the stored token; the browser cookie is rotated without one', () async {
    final native = MemoryStore('r1');
    final rotations = <String?>[];
    Future<RotatedSession> rotate(String? refresh) async {
      rotations.add(refresh);
      return RotatedSession(jwt(const Duration(minutes: 15), 'a'), refreshToken: refresh == null ? null : 'r2');
    }

    final s = rotating(native, rotate);
    addTearDown(s.dispose);
    expect(await s.restore(), SessionRestoration.authenticated);
    expect(native.value, 'r2');

    final web = MemoryStore('!cookie');
    final w = rotating(web, rotate);
    addTearDown(w.dispose);
    expect(await w.restore(), SessionRestoration.authenticated);
    expect(rotations, ['r1', null]);
    expect(web.value, '!cookie');
  });

  test('a rejected refresh ends the session on restore', () async {
    final store = MemoryStore('spent');
    final s = rotating(store, (_) async {
      final request = RequestOptions(path: '/account/refresh');
      throw DioException(requestOptions: request, response: Response(requestOptions: request, statusCode: 401));
    });
    addTearDown(s.dispose);
    expect(await s.restore(), SessionRestoration.rejected);
    expect(s.phase.value, SessionPhase.anonymous);
    expect(store.value, '!rejected');
  });
}

class _Recorder implements HttpClientAdapter {
  _Recorder(this.record);
  final void Function(RequestOptions) record;
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<List<int>>? body, Future<void>? cancel) async {
    record(options);
    return ResponseBody.fromString('{}', 200, headers: {'content-type': ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}
