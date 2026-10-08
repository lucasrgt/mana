import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mana_storage/mana_storage.dart';
import 'package:signals_core/signals_core.dart';

import 'src/session_coordination_stub.dart'
    if (dart.library.js_interop) 'src/session_coordination_web.dart';

/// Another context replaced the session; adopting it requires explicit restore.
final class SessionChanged implements Exception {
  const SessionChanged();
  @override
  String toString() => 'Session changed in another context';
}

final class SignInThrottled implements Exception {
  SignInThrottled(this.retryAt);
  final DateTime retryAt;

  factory SignInThrottled.fromResponse(Response<dynamic>? response) {
    final now = DateTime.now();
    final values = response?.headers['retry-after'];
    final seconds = values?.length == 1 ? int.tryParse(values!.single) : null;
    // Our server emits delta-seconds. Missing/malformed headers remain a
    // throttling error and never trigger automatic retries.
    return SignInThrottled(
      now.add(Duration(seconds: (seconds ?? 60).clamp(1, 3600))),
    );
  }
}

abstract interface class SessionStore {
  factory SessionStore.callbacks({
    required Future<String?> Function() read,
    required Future<void> Function(String value) write,
  }) = _CallbackSessionStore;
  Future<String?> read();
  Future<void> write(String value);
}

final class _CallbackSessionStore implements SessionStore {
  _CallbackSessionStore({
    required Future<String?> Function() read,
    required Future<void> Function(String value) write,
  }) : _read = read,
       _write = write;
  final Future<String?> Function() _read;
  final Future<void> Function(String value) _write;
  @override
  Future<String?> read() => _read();
  @override
  Future<void> write(String value) => _write(value);
}

final class SecureSessionStore implements SessionStore {
  SecureSessionStore(this.key, {FlutterSecureStorage? storage})
    : _storage = ManaSecureStorage(storage: storage),
      _coordination = SessionCoordination(
        (storage ?? const FlutterSecureStorage()).webOptions,
        key,
      );
  final String key;
  final ManaSecureStorage _storage;
  final SessionCoordination _coordination;
  bool get shared => _coordination.shared;
  Stream<void> get changes => _coordination.changes;
  @override
  Future<String?> read() => _storage.read(key: key);
  @override
  Future<void> write(String value) =>
      _coordination.exclusive(() => _writeConfirmed(value));

  /// Runs [action] while holding this record's cross-tab lock (web) — used to
  /// serialize refresh-token rotation, which a shared cookie makes tab-global.
  Future<T> exclusive<T>(Future<T> Function() action) => _coordination.exclusive(action);

  /// Atomic only on the coordinated web path; native callers retain their
  /// provider contract. AshSession uses this only when [shared] is true.
  Future<bool> writeIfCurrent(String? expected, String value) =>
      _coordination.exclusive(() async {
        if (await read() != expected) return false;
        await _writeConfirmed(value);
        return true;
      });

  Future<void> _writeConfirmed(String value) async {
    await _storage.write(key: key, value: value);
    final saved = await read();
    // The Linux plugin may return success without persisting a value. Do not
    // establish a session on an unconfirmed write. Native read maps '' to null.
    if (saved != value && !(value.isEmpty && saved == null)) {
      throw StateError('Session storage write was not confirmed');
    }
  }
}

final class SessionIdentity {
  const SessionIdentity({
    required this.userId,
    required this.email,
    required this.expiresAt,
  });
  final String userId;
  final String email;
  final DateTime expiresAt;
}

final class SignedSession {
  const SignedSession(this.token, this.identity, {this.refreshToken});
  final String token;
  final SessionIdentity identity;

  /// Rotating sessions only: the refresh token a native client must keep. Web
  /// clients receive it as an HttpOnly cookie instead, so it stays null.
  final String? refreshToken;
}

/// Credentials returned by rotating a refresh token.
final class RotatedSession {
  const RotatedSession(this.token, {this.refreshToken});
  final String token;
  final String? refreshToken;
}

/// The stored marker for a refresh token held by the browser as a cookie.
const _cookieRefresh = '!cookie';
const _rotation = #mana.session.rotation;

DateTime? _expiry(String jwt) {
  final parts = jwt.split('.');
  if (parts.length != 3) return null;
  try {
    final claims = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final exp = claims is Map ? claims['exp'] : null;
    return exp is int ? DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true) : null;
  } on FormatException {
    return null;
  }
}

enum SessionPhase { loading, authenticated, anonymous, unavailable }

enum SessionRestoration { empty, authenticated, rejected, unavailable }

/// Domain transport is injected from the app's generated client. This class
/// owns persistence, stale responses and bearer invalidation, never token minting.
///
/// With [rotate], sessions use short-lived access tokens kept only in memory and
/// a rotating refresh token: the store keeps the refresh token (native) or a
/// marker for the browser's HttpOnly cookie (web). Access is renewed shortly
/// before it expires, one rotation at a time and serialized across browser tabs.
/// Requests are still never replayed.
final class AshSession {
  AshSession({
    required this.dio,
    required this.store,
    required this.authenticate,
    required this.identify,
    required this.revoke,
    this.register,
    this.rotate,
    this.renewBefore = const Duration(minutes: 1),
  }) : _origin = Uri.parse(dio.options.baseUrl).origin {
    _interceptor = InterceptorsWrapper(
      onRequest: (request, handler) async {
        if (Zone.current[_rotation] == true) {
          handler.next(request);
          return;
        }
        if (rotate != null && _token != null && request.uri.origin == _origin) {
          final expires = _expiresAt;
          if (expires != null &&
              expires.difference(DateTime.now().toUtc()) < renewBefore) {
            await _renew(_generation);
          }
        }
        final token = _token;
        final generation = _generation;
        if (token != null && request.uri.origin == _origin) {
          try {
            final shared = _sharedStore;
            if (shared != null && await shared.read() != _observed) {
              if (_current(generation)) _sharedChanged();
              throw const SessionChanged();
            }
            if (!_current(generation)) throw const SessionChanged();
            request.headers['Authorization'] = 'Bearer $token';
            request.extra['mana.session.generation'] = generation;
          } catch (error) {
            if (_current(generation)) _sharedChanged(error: error);
            handler.reject(DioException(requestOptions: request, error: error));
            return;
          }
        }
        handler.next(request);
      },
      onResponse: (response, handler) {
        final generation =
            response.requestOptions.extra['mana.session.generation'];
        if (generation is int && !_current(generation)) {
          handler.reject(
            DioException(
              requestOptions: response.requestOptions,
              error: const SessionChanged(),
            ),
          );
          return;
        }
        handler.next(response);
      },
      onError: (error, handler) async {
        final rejected = error.requestOptions.headers['Authorization'];
        final dispatchedGeneration =
            error.requestOptions.extra['mana.session.generation'];
        if (!_disposed &&
            dispatchedGeneration is int &&
            _current(dispatchedGeneration) &&
            error.response?.statusCode == 401 &&
            _token != null &&
            rejected == 'Bearer $_token' &&
            error.requestOptions.uri.origin == _origin) {
          try {
            await _invalidate(rejected: true);
          } catch (error) {
            if (!_disposed) failure.value = error;
          }
        }
        // Never replay a request, especially a write, as part of session recovery.
        handler.next(error);
      },
    );
    dio.interceptors.add(_interceptor);
    _sharedChanges = _sharedStore?.changes.listen(
      (_) => _observeSharedChange(),
    );
  }
  /// The access token for a transport the interceptor does not cover (a
  /// websocket), renewed first when it is about to expire.
  Future<String?> accessToken() async {
    final expires = _expiresAt;
    if (rotate != null && _token != null && expires != null && expires.difference(DateTime.now().toUtc()) < renewBefore) {
      await _renew(_generation);
    }
    return _token;
  }

  final Dio dio;
  final SessionStore store;
  final Future<SignedSession> Function(String email, String password)
  authenticate;
  final Future<SessionIdentity> Function() identify;
  final Future<void> Function() revoke;
  final Future<SignedSession> Function(
    String email,
    String password,
    String confirmation,
  )?
  register;

  /// Exchanges the stored refresh token (null for the browser cookie) for new
  /// credentials. Enables rotating sessions.
  final Future<RotatedSession> Function(String? refreshToken)? rotate;
  final Duration renewBefore;
  final String _origin;
  DateTime? _expiresAt;
  Future<void>? _renewing;
  late final Interceptor _interceptor;
  final phase = signal(SessionPhase.loading);
  final identity = signal<SessionIdentity?>(null);
  final failure = signal<Object?>(null);
  final ended = signal(false);
  String? _token;
  String? _observed;
  StreamSubscription<void>? _sharedChanges;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _writes = Future.value();

  SecureSessionStore? get _sharedStore {
    final candidate = store;
    return candidate is SecureSessionStore && candidate.shared
        ? candidate
        : null;
  }

  void _sharedChanged({Object? error}) {
    ++_generation;
    _token = null;
    identity.value = null;
    ended.value = true;
    failure.value = error ?? const SessionChanged();
    phase.value = error == null || error is SessionChanged
        ? SessionPhase.anonymous
        : SessionPhase.unavailable;
  }

  Future<void> _observeSharedChange() async {
    final generation = _generation;
    try {
      final value = await store.read();
      if (_current(generation) && value != _observed) _sharedChanged();
    } catch (error) {
      if (_current(generation)) _sharedChanged(error: error);
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  Future<void> _save(String value, int generation) {
    final next = _writes.catchError((_) {}).then((_) async {
      if (!_current(generation)) return;
      final expected = _observed;
      final shared = _sharedStore;
      if (shared == null) {
        await store.write(value);
      } else if (!await shared.writeIfCurrent(expected, value)) {
        throw const SessionChanged();
      }
      // A write already in flight may finish after a local logout was queued.
      // The queued transition must compare against that actual committed value.
      _observed = value;
    });
    _writes = next;
    return next;
  }

  Future<void> _invalidate({bool rejected = false}) async {
    ended.value = rejected;
    final generation = ++_generation;
    _token = null;
    _expiresAt = null;
    identity.value = null;
    phase.value = SessionPhase.anonymous;
    // An explicit rejection/logout is distinct from never having signed in.
    // The lab may bootstrap an empty store, but must not silently undo logout.
    await _save(rejected ? '!rejected' : '', generation);
  }

  Future<SessionRestoration> restore() async {
    final generation = ++_generation;
    phase.value = SessionPhase.loading;
    failure.value = null;
    try {
      final token = await store.read();
      if (!_current(generation)) return SessionRestoration.rejected;
      _observed = token;
      if (token != null && token.startsWith('!retry:')) {
        final deadline = int.tryParse(token.substring(7));
        final now = DateTime.now();
        _token = null;
        identity.value = null;
        ended.value = false;
        if (deadline != null && deadline > now.millisecondsSinceEpoch) {
          failure.value = SignInThrottled(
            DateTime.fromMillisecondsSinceEpoch(deadline),
          );
        }
        phase.value = SessionPhase.anonymous;
        return SessionRestoration.rejected;
      }
      if (token == null || token.isEmpty || token == '!rejected') {
        ended.value = token == '!rejected';
        _token = null;
        identity.value = null;
        phase.value = SessionPhase.anonymous;
        return token == null
            ? SessionRestoration.empty
            : SessionRestoration.rejected;
      }
      if (rotate != null) {
        final rotated = await _rotated(token, generation);
        if (rotated == null) return SessionRestoration.rejected;
      } else {
        _token = token;
      }
      final user = await identify();
      if (!_current(generation)) return SessionRestoration.rejected;
      if (_sharedStore != null && await store.read() != _observed) {
        if (_current(generation)) _sharedChanged();
        return SessionRestoration.rejected;
      }
      if (!_current(generation)) return SessionRestoration.rejected;
      ended.value = false;
      identity.value = user;
      phase.value = SessionPhase.authenticated;
      return SessionRestoration.authenticated;
    } catch (error) {
      if (_current(generation)) {
        if (error is DioException && error.response?.statusCode == 401) {
          await _invalidate(rejected: true);
          return SessionRestoration.rejected;
        }
        failure.value = error;
        _token = null;
        identity.value = null;
        phase.value = SessionPhase.unavailable;
        return SessionRestoration.unavailable;
      }
      return SessionRestoration.rejected;
    }
  }

  Future<void> signIn(String email, String password) =>
      _establish(() => authenticate(email, password));

  Future<void> signUp(String email, String password, String confirmation) {
    final action = register;
    if (action == null)
      throw UnsupportedError('Registration is not configured');
    return _establish(() => action(email, password, confirmation));
  }

  /// Adopts credentials obtained another way (e.g. a federated sign-in), with
  /// the same persistence and throttling rules as [signIn].
  Future<void> establish(Future<SignedSession> Function() action) =>
      _establish(action);

  Future<void> _establish(Future<SignedSession> Function() action) async {
    final previous = failure.value;
    if (previous is SignInThrottled &&
        previous.retryAt.isAfter(DateTime.now())) {
      throw previous;
    }
    final generation = ++_generation;
    phase.value = SessionPhase.loading;
    failure.value = null;
    // Authentication must not inherit the previous account's bearer.
    _token = null;
    identity.value = null;
    try {
      if (_sharedStore != null) {
        final observed = await store.read();
        if (!_current(generation)) return;
        _observed = observed;
      }
      final session = await action();
      if (!_current(generation)) return;
      await _save(
        rotate == null ? session.token : session.refreshToken ?? _cookieRefresh,
        generation,
      );
      if (!_current(generation)) return;
      ended.value = false;
      _token = session.token;
      _expiresAt = rotate == null ? null : _expiry(session.token);
      identity.value = session.identity;
      phase.value = SessionPhase.authenticated;
    } catch (error, stack) {
      final problem = error is DioException && error.response?.statusCode == 429
          ? SignInThrottled.fromResponse(error.response)
          : error;
      if (_current(generation)) {
        _token = null;
        identity.value = null;
        failure.value = problem;
        phase.value = SessionPhase.anonymous;
        if (problem is SignInThrottled) {
          await _save(
            '!retry:${problem.retryAt.millisecondsSinceEpoch}',
            generation,
          );
        }
      }
      Error.throwWithStackTrace(problem, stack);
    }
  }

  Future<void> signOut() async {
    final generation = ++_generation;
    failure.value = null;
    try {
      if (_token != null) await revoke();
      if (!_current(generation)) return;
      await _invalidate();
    } catch (error) {
      if (_current(generation)) failure.value = error;
      rethrow; // A failed revocation must not be reported as successful logout.
    }
  }

  /// Rotates [stored] and adopts the new credentials. Returns null when the
  /// session was rejected (and has been ended) or superseded meanwhile.
  Future<RotatedSession?> _rotated(String stored, int generation) async {
    Future<RotatedSession> exchange() => runZoned(
      () => rotate!(stored == _cookieRefresh ? null : stored),
      zoneValues: {_rotation: true},
    );
    final shared = _sharedStore;
    final rotated = shared == null ? await exchange() : await shared.exclusive(exchange);
    if (!_current(generation)) return null;
    await _save(rotated.refreshToken ?? _cookieRefresh, generation);
    if (!_current(generation)) return null;
    _token = rotated.token;
    _expiresAt = _expiry(rotated.token);
    return rotated;
  }

  Future<void> _renew(int generation) => _renewing ??= () async {
    try {
      final stored = _observed;
      if (stored == null || stored.isEmpty || stored.startsWith('!') && stored != _cookieRefresh) return;
      await _rotated(stored, generation);
    } on DioException catch (error) {
      if (_current(generation) && error.response?.statusCode == 401) {
        await _invalidate(rejected: true);
      } else if (_current(generation)) {
        failure.value = error;
      }
    } catch (error) {
      if (_current(generation)) failure.value = error;
    } finally {
      _renewing = null;
    }
  }();

  void dispose() {
    _disposed = true;
    ++_generation;
    _sharedChanges?.cancel();
    dio.interceptors.remove(_interceptor);
    phase.dispose();
    identity.dispose();
    failure.dispose();
    ended.dispose();
  }
}
