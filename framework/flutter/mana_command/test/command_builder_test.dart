import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

enum Reason { taken }

void main() {
  testWidgets('renders each command state and unwraps typed refusals', (
    tester,
  ) async {
    var fail = true;
    final command = Command1<String, String>(
      (value) async =>
          fail ? Failure(const Refusal(Reason.taken)) : Success('ok $value'),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CommandBuilder<String>(
          command: command,
          idle: (_) => const Text('idle'),
          running: (_) => const Text('running'),
          failure: (_, reason) => Text('failed $reason'),
          success: (_, value) => Text(value),
        ),
      ),
    );
    expect(find.text('idle'), findsOneWidget);
    await command.execute('a');
    await tester.pump();
    expect(find.text('failed Reason.taken'), findsOneWidget);
    fail = false;
    await command.execute('b');
    await tester.pump();
    expect(find.text('ok b'), findsOneWidget);
    command.dispose();
  });
}
