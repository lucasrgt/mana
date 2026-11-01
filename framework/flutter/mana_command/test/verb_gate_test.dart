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

  testWidgets('the control carries its verb, and its record, as its key', (
    tester,
  ) async {
    await tester.pumpWidget(
      host(
        Column(
          children: [
            VerbGate(
              key: const ValueKey('gate'),
              verb: cancel,
              offered: const ['cancel'],
              recordId: '42',
              run: () async {},
              builder: button,
            ),
            VerbGate(
              verb: apply,
              offered: const ['apply_coupon'],
              run: () async {},
              builder: button,
            ),
            VerbGate(
              verb: apply,
              offered: const [],
              recordId: '7',
              run: () async {},
              builder: button,
            ),
          ],
        ),
      ),
    );
    expect(find.byKey(const ValueKey('gate')), findsOneWidget);
    expect(
      VerbGate.keyFor(cancel, recordId: '42'),
      const ValueKey('verb:booking.cancel:42'),
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('verb:booking.cancel:42')),
        matching: find.text('on'),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('verb:order.apply_coupon')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('verb:order.apply_coupon:7')),
      findsNothing,
    );
  });

  testWidgets(
    'while Moments run, mounted gates offer what their record offers',
    (tester) async {
      final performed = <String>[];
      MomentAffordances.enable(performing: performed.add);
      addTearDown(MomentAffordances.disable);
      Widget gates(List<String> offered, {bool second = true}) => host(
        Column(
          children: [
            VerbGate(
              verb: apply,
              offered: offered,
              recordId: '1',
              run: () async {},
              builder: button,
            ),
            if (second)
              VerbGate(
                verb: apply,
                offered: offered,
                recordId: '2',
                run: () async {},
                builder: button,
              ),
          ],
        ),
      );
      await tester.pumpWidget(gates(const ['apply_coupon']));
      expect(MomentAffordances.offered, [
        'order.apply_coupon:1',
        'order.apply_coupon:2',
      ]);
      await tester.pumpWidget(gates(const ['apply_coupon'], second: false));
      expect(MomentAffordances.offered, ['order.apply_coupon:1']);
      await tester.tap(find.text('on'));
      await tester.pump();
      expect(performed, ['order.apply_coupon:1']);
      await tester.pumpWidget(gates(const []));
      expect(MomentAffordances.offered, isEmpty);
      await tester.pumpWidget(host(const SizedBox()));
      expect(MomentAffordances.offered, isEmpty);
    },
  );
}
