import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/src/moment_gestures.dart';

void main() {
  testWidgets(
    'explicit reveal scrolls a mounted target without invoking its action',
    (tester) async {
      var taps = 0;
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              child: Column(
                children: [
                  const SizedBox(height: 1800),
                  ElevatedButton(
                    key: const ValueKey('below-fold'),
                    onPressed: () => taps++,
                    child: const Text('Submit'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final gestures = MomentGestures();
      expect(
        await tester.runAsync(
          () => gestures.tap(
            'below-fold',
            current: () => true,
            patience: Duration.zero,
          ),
        ),
        'not-visible',
      );
      expect(
        await tester.runAsync(
          () => gestures.reveal('below-fold', current: () => false),
        ),
        'stale',
      );
      expect(scroll.offset, 0);
      expect(
        await tester.runAsync(
          () => gestures.reveal('below-fold', current: () => true),
        ),
        'dispatched',
      );
      await tester.pump();
      expect(scroll.offset, greaterThan(0));
      expect(taps, 0);
      expect(
        await tester.runAsync(
          () => gestures.tap('below-fold', current: () => true),
        ),
        'dispatched',
      );
      expect(taps, 1);
    },
  );
  testWidgets(
    'fill traverses focus and text input formatters without submitting',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      var changes = 0, submissions = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              key: const ValueKey('field'),
              controller: controller,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onChanged: (_) => changes++,
              onSubmitted: (_) => submissions++,
            ),
          ),
        ),
      );
      final outcome = await tester.runAsync(
        () => MomentGestures().fill('field', 'a12b', current: () => true),
      );
      await tester.pump();
      expect(outcome, 'dispatched');
      expect(controller.text, '12');
      expect(changes, 1);
      expect(submissions, 0);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              key: const ValueKey('field'),
              controller: controller,
              readOnly: true,
            ),
          ),
        ),
      );
      expect(
        await tester.runAsync(
          () => MomentGestures().fill('field', '999', current: () => true),
        ),
        'unsupported',
      );
      expect(controller.text, '12');
    },
  );
  testWidgets(
    'losing ownership after pointer down cancels the tap and reports uncertainty',
    (tester) async {
      var downs = 0, taps = 0, probes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Listener(
            onPointerDown: (_) => downs++,
            child: Center(
              child: ElevatedButton(
                key: const ValueKey('action'),
                onPressed: () => taps++,
                child: const Text('Read'),
              ),
            ),
          ),
        ),
      );
      final result = await tester.runAsync(
        () => MomentGestures().tap('action', current: () => ++probes == 1),
      );
      expect(result, 'dispatch-unknown');
      expect(downs, 1);
      expect(taps, 0);
      expect(
        await tester.runAsync(
          () => MomentGestures().tap('action', current: () => true),
        ),
        'dispatched',
      );
      expect(
        taps,
        1,
      ); // Cancelled pointers must not poison the following gesture.
    },
  );
  testWidgets('tap traverses hit testing and the button gesture handler once', (
    tester,
  ) async {
    var count = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: ElevatedButton(
            key: const ValueKey('action'),
            onPressed: () => count++,
            child: const Text('Read'),
          ),
        ),
      ),
    );
    final result = await tester.runAsync(
      () => MomentGestures().tap('action', current: () => true),
    );
    await tester.pump();
    expect(result, 'dispatched');
    expect(count, 1);
  });

  testWidgets(
    'missing, ambiguous, hidden and occluded targets never invoke handlers',
    (tester) async {
      var count = 0;
      Widget button() => ElevatedButton(
        key: const ValueKey('action'),
        onPressed: () => count++,
        child: const Text('Read'),
      );
      final gestures = MomentGestures();
      Future<String?> tap() => tester.runAsync(
        () => gestures.tap(
          'action',
          current: () => true,
          patience: Duration.zero,
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(await tap(), 'not-found');
      await tester.pumpWidget(
        MaterialApp(
          home: Row(
            children: [
              Center(child: button()),
              Center(child: button()),
            ],
          ),
        ),
      );
      expect(await tap(), 'ambiguous');
      await tester.pumpWidget(MaterialApp(home: Offstage(child: button())));
      expect(await tap(), 'not-visible');
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(
            children: [
              Center(child: button()),
              const Positioned.fill(child: ModalBarrier(dismissible: false)),
            ],
          ),
        ),
      );
      expect(await tap(), 'occluded');
      expect(count, 0);
    },
  );

  testWidgets(
    'a changed revision rejects dispatch and disabled widgets cannot fake effects',
    (tester) async {
      var count = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ElevatedButton(
              key: const ValueKey('action'),
              onPressed: () => count++,
              child: const Text('Read'),
            ),
          ),
        ),
      );
      expect(
        await tester.runAsync(
          () => MomentGestures().tap('action', current: () => false),
        ),
        'stale',
      );
      expect(count, 0);
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: ElevatedButton(
              key: ValueKey('action'),
              onPressed: null,
              child: Text('Read'),
            ),
          ),
        ),
      );
      expect(
        await tester.runAsync(
          () => MomentGestures().tap(
            'action',
            current: () => true,
            patience: Duration.zero,
          ),
        ),
        'disabled',
      );
      expect(count, 0);
    },
  );

  testWidgets('a tap waits out a target that is not there yet', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final watch = Stopwatch()..start();
    final outcome = await tester.runAsync(
      () => MomentGestures().tap(
        'action',
        current: () => true,
        patience: const Duration(milliseconds: 300),
      ),
    );
    expect(outcome, 'not-found');
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(300));
  });

  testWidgets('a fill waits out a field that is not there yet', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    final watch = Stopwatch()..start();
    final outcome = await tester.runAsync(
      () => MomentGestures().fill(
        'field',
        'text',
        current: () => true,
        patience: const Duration(milliseconds: 300),
      ),
    );
    expect(outcome, 'not-found');
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(300));
  });

  testWidgets('a tap finds an option a lazy list has not built yet', (
    tester,
  ) async {
    String? chosen;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemCount: 60,
            itemExtent: 48,
            itemBuilder: (_, index) => TextButton(
              key: ValueKey('option-$index'),
              onPressed: () => chosen = '$index',
              child: Text('Option $index'),
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('option-52')), findsNothing);
    final outcome = await tester.runAsync(
      () => MomentGestures().tap('option-52', current: () => true),
    );
    await tester.pump();
    expect(outcome, 'dispatched');
    expect(chosen, '52');
  });

  testWidgets('back closes the dialog on top as the system button would', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (inner) {
            context = inner;
            return const SizedBox();
          },
        ),
      ),
    );
    final closed = showDialog<void>(
      context: context,
      builder: (_) => const AlertDialog(content: Text('Sure?')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sure?'), findsOneWidget);
    expect(
      await tester.runAsync(() => MomentGestures().back(current: () => true)),
      'dispatched',
    );
    await tester.pumpAndSettle();
    expect(find.text('Sure?'), findsNothing);
    await closed;
  });

  testWidgets('a swipe turns a page view to the next page', (tester) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PageView(
          key: const ValueKey('pages'),
          controller: pages,
          children: const [Text('first'), Text('second')],
        ),
      ),
    );
    final outcome = await tester.runAsync(
      () => MomentGestures().swipe('pages', 'left', current: () => true),
    );
    await tester.pumpAndSettle();
    expect(outcome, 'dispatched');
    expect(pages.page, 1);
    expect(
      await tester.runAsync(
        () => MomentGestures().swipe('pages', 'sideways', current: () => true),
      ),
      'unsupported',
    );
  });

  testWidgets('a long press reaches the long-press handler, not the tap', (
    tester,
  ) async {
    var taps = 0, holds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GestureDetector(
            key: const ValueKey('held'),
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            onLongPress: () => holds++,
            child: const SizedBox(width: 80, height: 80),
          ),
        ),
      ),
    );
    final outcome = await tester.runAsync(
      () => MomentGestures().longPress('held', current: () => true),
    );
    await tester.pump();
    expect(outcome, 'dispatched');
    expect((taps, holds), (0, 1));
  });

  testWidgets('submit runs the field\'s keyboard action once', (tester) async {
    final submitted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TextField(
            key: const ValueKey('search'),
            controller: TextEditingController(text: 'pizza'),
            textInputAction: TextInputAction.search,
            onSubmitted: submitted.add,
          ),
        ),
      ),
    );
    final outcome = await tester.runAsync(
      () => MomentGestures().submit('search', current: () => true),
    );
    await tester.pump();
    expect(outcome, 'dispatched');
    expect(submitted, ['pizza']);
  });
}
