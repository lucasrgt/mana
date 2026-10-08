import 'package:ash_session/ash_session.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final returned in <String?>[null, 'different-session']) {
    test(
      'unconfirmed secure write does not establish a session ($returned)',
      () async {
        var writes = 0;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'write') {
            writes++;
            return null;
          }
          if (call.method == 'read') return returned;
          throw StateError('Unexpected storage operation');
        });
        final identity = SessionIdentity(
          userId: 'synthetic',
          email: 'actor@moments.invalid',
          expiresAt: DateTime.utc(2099),
        );
        final session = AshSession(
          dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1')),
          store: SecureSessionStore('synthetic-key'),
          authenticate: (_, _) async =>
              SignedSession('synthetic-session', identity),
          identify: () async => identity,
          revoke: () async {},
        );
        addTearDown(session.dispose);
        await expectLater(
          session.signIn('synthetic', 'synthetic'),
          throwsStateError,
        );
        expect(
          writes,
          1,
        ); // No retry or second authentication to mask the failure.
        expect(session.phase.value, SessionPhase.anonymous);
        expect(session.identity.value, isNull);
      },
    );
  }

  test(
    'confirmed write succeeds and empty native reads mean cleared storage',
    () async {
      String? value;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'write') {
          final next = (call.arguments as Map)['value'] as String;
          value = next.isEmpty ? null : next;
          return null;
        }
        if (call.method == 'read') return value;
        throw StateError('Unexpected storage operation');
      });
      final store = SecureSessionStore('synthetic-key');
      await store.write('synthetic-session');
      expect(await store.read(), 'synthetic-session');
      await store.write('');
      expect(await store.read(), isNull);
    },
  );
}
