import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/src/configuration.dart';
import 'package:live_ui/src/scope.dart';

void main() {
  testWidgets(
    'Moments opt-in does not connect the archived presentation editor',
    (tester) async {
      expect(
        momentsEnabled,
        isTrue,
        reason: 'Run this boundary check with --dart-define=MANA_MOMENTS=true',
      );
      expect(liveUiEnabled, isFalse);
      await tester.pumpWidget(
        LiveUiHost(
          child: Builder(
            builder: (context) {
              expect(LiveUiScope.of(context), isNull);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    },
    skip: !momentsEnabled || liveUiEnabled,
  );
}
