import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const cancel = ManaVerb(
  resource: 'booking',
  name: 'cancel',
  action: 'cancel',
  risk: VerbRisk.money,
);
const apply = ManaVerb(
  resource: 'order',
  name: 'apply_coupon',
  action: 'apply_coupon',
  inverse: 'remove_coupon',
);

Widget host(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

Widget button(BuildContext context, VoidCallback? onPressed) => GestureDetector(
  onTap: onPressed,
  child: Text(onPressed == null ? 'off' : 'on'),
);

void main() {
  testWidgets(
    'a verb the record does not offer is hidden, or disabled on request',
    (tester) async {
      await tester.pumpWidget(
        host(
          VerbGate(
            verb: cancel,
            offered: const ['accept'],
            run: () async {},
            builder: button,
          ),
        ),
      );
      expect(find.text('on'), findsNothing);
      expect(find.text('off'), findsNothing);
      await tester.pumpWidget(
        host(
          VerbGate(
            verb: cancel,
            offered: const ['accept'],
            run: () async {},
            builder: button,
            hideWhenNotOffered: false,
          ),
        ),
      );
      expect(find.text('off'), findsOneWidget);
    },
  );

  testWidgets('a money verb runs only after confirmation', (tester) async {
    var ran = 0;
    var answer = false;
    await tester.pumpWidget(
      host(
        VerbGate(
          verb: cancel,
          offered: const ['cancel'],
          run: () async => ran++,
          confirm: (_, _) async => answer,
          builder: button,
        ),
      ),
    );
    await tester.tap(find.text('on'));
    await tester.pump();
    expect(ran, 0);
    answer = true;
    await tester.tap(find.text('on'));
    await tester.pump();
    expect(ran, 1);
  });

  testWidgets('a verb with an inverse offers Undo after it runs', (
    tester,
  ) async {
    var undone = 0;
    Future<void> Function()? offeredUndo;
    await tester.pumpWidget(
      host(
        VerbGate(
          verb: apply,
          offered: const ['apply_coupon'],
          run: () async {},
          undo: () async => undone++,
          showUndo: (_, _, undo) => offeredUndo = undo,
          builder: button,
        ),
      ),
    );
    await tester.tap(find.text('on'));
    await tester.pump();
    expect(offeredUndo, isNotNull);
    await offeredUndo!();
    expect(undone, 1);
  });

  testWidgets(
    'a verb with inputs collects them, then confirms, then runs with them',
    (tester) async {
      const counter = ManaVerb(
        resource: 'booking',
        name: 'cancel',
        action: 'cancel',
        risk: VerbRisk.money,
        inputs: [
          VerbInput(
            name: 'reason',
            type: 'string',
            required: true,
            oneOf: ['no_show', 'other'],
          ),
        ],
      );
      Map<String, Object?>? given;
      Map<String, Object?>? ran;
      var asked = 0;
      await tester.pumpWidget(
        host(
          VerbGate(
            verb: counter,
            offered: const ['cancel'],
            collect: (_, _) async => given,
            confirm: (_, _) async {
              asked++;
              return true;
            },
            runWith: (inputs) async => ran = inputs,
            builder: button,
          ),
        ),
      );
      await tester.tap(find.text('on'));
      await tester.pump();
      expect((ran, asked), (null, 0));

      given = {'reason': 'other'};
      await tester.tap(find.text('on'));
      await tester.pump();
      expect(ran, {'reason': 'other'});
      expect(asked, 1);
      expect(verbInputRefusals(counter, {'reason': 'late'}), {
        'reason': 'one_of',
      });
    },
  );
}
