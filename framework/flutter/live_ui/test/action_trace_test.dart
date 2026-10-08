import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/src/action_trace.dart';

void main() {
  const gesture = '10000000-0000-4000-8000-000000000001';
  String receipt(String id, {int version = 1}) => base64Url.encode(
    utf8.encode(
      jsonEncode({
        'version': version,
        'gesture': id,
        'request': 'a' * 32,
        'truncated': false,
        'scope': 'request-actions-only',
        'coverage': 'not-established',
        'actions': [],
      }),
    ),
  );
  test(
    'async gesture work inherits its scope without attributing outside work',
    () async {
      final records = <Map<String, dynamic>>[];
      expect(MomentActionTrace.current, isNull);
      await MomentActionTrace.run(
        gesture,
        (value) async => records.add(value),
        () async {
          await Future<void>.delayed(Duration.zero);
          expect(MomentActionTrace.current?.gesture, gesture);
          await MomentActionTrace.current!.record(receipt(gesture));
          await MomentActionTrace.current!.record(receipt(gesture, version: 2));
          await MomentActionTrace.current!.record(receipt(gesture, version: 3));
          await MomentActionTrace.current!.record(receipt(gesture, version: 4));
          await MomentActionTrace.current!.record(receipt('different-gesture'));
          await MomentActionTrace.current!.record('not-base64');
          await MomentActionTrace.current!.record(null);
        },
      );
      expect(records, hasLength(3));
      expect(records.map((record) => record['version']), [1, 2, 3]);
      expect(MomentActionTrace.current, isNull);
    },
  );
  test(
    'failed evidence delivery does not fail the business continuation',
    () async {
      final result = await MomentActionTrace.run(
        gesture,
        (_) async => throw StateError('offline'),
        () async {
          await MomentActionTrace.current!.record(receipt(gesture));
          return 'business-result';
        },
      );
      expect(result, 'business-result');
    },
  );
  test('development metadata stays on the exact loopback API origin', () {
    final api = Uri.parse('http://127.0.0.1:5198');
    expect(MomentActionTrace.allows(api.resolve('/api/tasks'), api), isFalse);
    expect(
      MomentActionTrace.allows(
        api.resolve('/api/tasks'),
        api,
        backendEnabled: true,
      ),
      isTrue,
    );
    for (final destination in [
      'https://example.com/api',
      'http://127.0.0.1:5258/api',
      'http://localhost:5198/api',
      'http://user@127.0.0.1:5198/api',
    ]) {
      expect(
        MomentActionTrace.allows(
          Uri.parse(destination),
          api,
          backendEnabled: true,
        ),
        isFalse,
      );
    }
  });
}
