import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  final origin = Uri.parse('http://127.0.0.1:5316');
  final valid = <String, dynamic>{
    'version': 1,
    'origin': origin.origin,
    'apiUrl': 'http://127.0.0.1:6001',
    'bridgeUrl': 'http://127.0.0.1:6002',
    'bridgeToken': 'a' * 48,
  };
  test(
    'ordinary startup preserves declared configuration without network',
    () async {
      await MomentRuntime.initialize();
      expect(
        MomentRuntime.apiUrl('https://api.example.test'),
        'https://api.example.test',
      );
    },
  );
  test('runtime settings bind both local services to this actor origin', () {
    final settings = MomentRuntimeSettings.parse(valid, origin: origin);
    expect(settings.apiUrl, 'http://127.0.0.1:6001');
    expect(settings.bridgeUrl, 'http://127.0.0.1:6002');
    for (final invalid in [
      {...valid, 'origin': 'http://127.0.0.1:5317'},
      {...valid, 'apiUrl': 'https://external.example'},
      {...valid, 'bridgeUrl': 'http://user:secret@127.0.0.1:6002'},
      {...valid, 'bridgeUrl': 'http://127.0.0.1:6002/path'},
      {...valid, 'bridgeToken': 'invalid'},
    ]) {
      expect(
        () => MomentRuntimeSettings.parse(invalid, origin: origin),
        throwsStateError,
      );
    }
  });
  test('shared-origin configuration must match the selected surface', () {
    const selected = '11111111-1111-4111-8111-111111111111';
    const other = '22222222-2222-4222-8222-222222222222';
    final scoped = {...valid, 'version': 2, 'surface': selected};
    expect(
      MomentRuntimeSettings.parse(
        scoped,
        origin: origin,
        surface: selected,
      ).surface,
      selected,
    );
    expect(
      MomentRuntimeSettings.parse(
        scoped,
        origin: origin,
        surface: selected,
      ).bridgeUrl,
      valid['bridgeUrl'],
    );
    for (final surface in [null, other, 'invalid']) {
      expect(
        () => MomentRuntimeSettings.parse(
          scoped,
          origin: origin,
          surface: surface,
        ),
        throwsStateError,
      );
    }
    expect(
      () => MomentRuntimeSettings.parse({
        ...valid,
        'surface': selected,
      }, origin: origin),
      throwsStateError,
    );
    // Existing single-actor hosts keep their v1 contract with owned URL nonces.
    expect(
      MomentRuntimeSettings.parse(
        valid,
        origin: origin,
        surface: selected,
      ).apiUrl,
      valid['apiUrl'],
    );
  });
}
