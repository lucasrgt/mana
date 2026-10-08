import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  if (!const bool.fromEnvironment('MANA_MOMENT_BOOTSTRAP')) {
    test('ordinary startup does not use a backend moment', () async {
      expect(
        await prepareMomentLaunch(
          apiUrl: 'https://production.invalid',
          signIn: (_, _) async => fail('Must not sign in'),
        ),
        isNull,
      );
    });
    return;
  }
  const apiUrl = 'http://127.0.0.1:5187';
  test(
    'sandbox signs in through supplied session seam before returning route',
    () async {
      var signedIn = false;
      final client = MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-bridge-token');
        return http.Response(
          jsonEncode({
            'apiUrl': apiUrl,
            'route': '/traveler/reservations?debugSession=0',
            'account': {
              'email': 'fixture@moments.invalid',
              'password': 'local-only',
            },
          }),
          200,
        );
      });
      final route = await prepareMomentLaunch(
        apiUrl: apiUrl,
        client: client,
        signIn: (email, password) async {
          expect(email, 'fixture@moments.invalid');
          expect(password, 'local-only');
          signedIn = true;
        },
      );
      expect(signedIn, isTrue);
      expect(route, '/traveler/reservations?debugSession=0');
    },
  );
  test('mismatched backend never receives the fixture credentials', () async {
    var signedIn = false;
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'apiUrl': 'http://127.0.0.1:9999',
          'route': '/traveler/reservations',
          'account': {
            'email': 'fixture@moments.invalid',
            'password': 'local-only',
          },
        }),
        200,
      ),
    );
    await expectLater(
      prepareMomentLaunch(
        apiUrl: apiUrl,
        client: client,
        signIn: (_, _) async {
          signedIn = true;
        },
      ),
      throwsStateError,
    );
    expect(signedIn, isFalse);
  });
  test('owned session is restored without invoking a legacy login', () async {
    var restored = false;
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'apiUrl': apiUrl,
          'route': '/notifications',
          'session': {'kind': 'ash-lab', 'accessToken': 'local-token'},
        }),
        200,
      ),
    );
    expect(
      await prepareMomentLaunch(
        apiUrl: apiUrl,
        client: client,
        signIn: (_, _) async => fail('Legacy login must not run'),
        restoreSession: (session) async {
          expect(session['accessToken'], 'local-token');
          restored = true;
        },
      ),
      '/notifications',
    );
    expect(restored, isTrue);
  });

  test(
    'whole launch callback receives validated private preparation only once',
    () async {
      var prepared = 0;
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'apiUrl': apiUrl,
            'route': '/sign-in',
            'account': {
              'email': 'local@moments.invalid',
              'password': 'local-secret',
            },
            'session': {
              'seed': {'kind': 'expired', 'accessToken': 'expired-token'},
            },
          }),
          200,
        ),
      );
      await prepareMomentLaunch(
        apiUrl: apiUrl,
        client: client,
        signIn: (_, _) async => fail('Do not also execute the default login'),
        onLaunch: (launch) async {
          prepared++;
          expect(launch['session']['seed']['kind'], 'expired');
        },
      );
      expect(prepared, 1);
    },
  );
}
