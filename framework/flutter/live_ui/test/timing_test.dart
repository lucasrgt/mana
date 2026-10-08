import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  test(
    'disabled instrumentation still executes and propagates failures',
    () async {
      MomentTiming.start(enabled: false);
      expect(
        await MomentTiming.measure(MomentStage.preferences, () async => 42),
        42,
      );
      await expectLater(
        MomentTiming.measure(
          MomentStage.preferences,
          () async => throw StateError('local'),
        ),
        throwsStateError,
      );
      expect(MomentTiming.snapshot(), isNull);
    },
  );
  test(
    'spans are bounded; reset cannot receive completion from previous runtime',
    () async {
      MomentTiming.start(enabled: true);
      MomentTiming.mark(MomentMark.runApp);
      final pending = MomentTiming.measure(
        MomentStage.preferences,
        () async => 42,
      );
      MomentTiming.start(enabled: true);
      await pending;
      expect(MomentTiming.snapshot()!['spans'], isEmpty);
      for (var i = 0; i < 40; i++) {
        await MomentTiming.measure(MomentStage.screenData, () async => i);
      }
      final snapshot = MomentTiming.snapshot()!;
      expect(snapshot['spans'], hasLength(32));
      expect((snapshot['marks'] as Map).keys, ['main']);
      MomentTiming.start(enabled: false);
    },
  );
}
