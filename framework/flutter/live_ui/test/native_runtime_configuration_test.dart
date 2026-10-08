import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  final valid = <String, dynamic>{
    'version': 1,
    'apiUrl': 'http://127.0.0.1:6001',
    'bridgeUrl': 'http://127.0.0.1:6002',
    'bridgeToken': 'a' * 48,
  };
  String route(Object value) =>
      '/__mana_moments?configuration=${Uri.encodeComponent(jsonEncode(value))}';
  test('native actor settings preserve the local capability and API', () {
    final settings = MomentRuntimeSettings.parseNativeRoute(route(valid));
    expect(settings.apiUrl, valid['apiUrl']);
    expect(settings.bridgeToken, valid['bridgeToken']);
    expect(settings.surface, isNull);
  });
  test(
    'native envelope refuses malformed, foreign or ambiguous configuration',
    () {
      for (final invalid in [
        '/tasks',
        '${route(valid)}&configuration=duplicate',
        '${route(valid)}&extra=1',
        '${route(valid)}#fragment',
        'http://127.0.0.1${route(valid)}',
        '/__mana_moments?configuration=%7B',
        route('unexpected'),
        route({...valid, 'version': 2}),
        route({...valid, 'bridgeToken': 'invalid'}),
        route({...valid, 'apiUrl': 'https://foreign.test'}),
        route({...valid, 'bridgeUrl': 'http://user:secret@127.0.0.1:6002'}),
        route({...valid, 'bridgeUrl': 'http://127.0.0.1:6002/path'}),
        route({...valid, 'extra': 'unexpected'}),
        route({...valid, 'bridgeToken': 'a' * 8192}),
      ]) {
        expect(
          () => MomentRuntimeSettings.parseNativeRoute(invalid),
          throwsStateError,
        );
      }
    },
  );
  test(
    'explicit native bootstrap consumes the platform envelope before routing',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      binding.platformDispatcher.defaultRouteNameTestValue = route(valid);
      addTearDown(binding.platformDispatcher.clearDefaultRouteNameTestValue);
      await MomentRuntime.initialize();
      expect(MomentRuntime.nativeBootstrap, isTrue);
      expect(MomentRuntime.apiUrl(''), valid['apiUrl']);
      expect(MomentRuntime.bridgeToken, valid['bridgeToken']);
    },
    skip: !const bool.fromEnvironment('MANA_RUNTIME_BOOTSTRAP'),
  );
}
