import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  final id = DraftField.id('transactionId');
  final text = DraftField.text('comment', maxLength: 20);
  final scores = DraftField.ratings('scores', min: 1, max: 5, maxEntries: 2);
  final modal = DraftField.choice(
    'modal',
    values: ['closed', 'rating'],
    initial: 'closed',
  );
  Map<String, dynamic> projection() => {
    'route': '/review',
    'transactionId': 'one',
    'comment': 'saved text',
    'commentBase': 2,
    'commentExtent': 7,
    'focus': 'comment',
    'scores': {'service': 4},
    'modal': 'rating',
    'scrollOffset': 0,
  };
  MomentDraft draft({
    FutureOr<void> Function()? restoreView,
    bool Function()? focusWhen,
  }) => MomentDraft(
    route: '/review',
    fields: [id, text, scores, modal],
    restoreView: restoreView ?? () {},
    focusWhen: focusWhen,
  );

  testWidgets(
    'typed values are isolated across drafts; resetting only chosen fields preserves others',
    (tester) async {
      final first = draft(), second = draft();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      first.write(id, 'one');
      first.write(text, 'hello');
      first.read(scores)['service'] = 4;
      expect(second.read(scores), isEmpty);
      expect(second.read(text), '');
      final snapshot = first.snapshot();
      first.read(scores)['service'] = 5;
      expect(snapshot['scores'], {'service': 4});
      first.reset([text, scores]);
      expect(first.read(id), 'one');
      expect(first.read(text), '');
      expect(first.read(scores), isEmpty);
      expect(
        () => first.read(DraftField.id('transactionId')),
        throwsArgumentError,
      );
    },
  );

  testWidgets(
    'invalid restored data changes no live field and never opens a view',
    (tester) async {
      var mounted = 0;
      final value = draft(
        restoreView: () {
          mounted++;
        },
      );
      addTearDown(value.dispose);
      value.write(text, 'existing');
      value.write(id, 'old');
      for (final change in [
        {
          'scores': {'service': 6},
        },
        {'comment': 42},
        {'comment': 'x' * 21},
        {
          'scores': {'service': '4'},
        },
        {
          'scores': {'a': 1, 'b': 2, 'c': 3},
        },
        {'modal': 'unknown'},
        {'commentBase': 'bad'},
        {'focus': 'password'},
      ]) {
        await expectLater(
          value.binding.restore({...projection(), ...change}),
          throwsFormatException,
        );
        expect(value.read(text), 'existing');
        expect(value.read(id), 'old');
        expect(mounted, 0);
      }
    },
  );

  testWidgets(
    'selection and focus restore after mounting; blur preserves editing focus and closed view suppresses it',
    (tester) async {
      var allowFocus = true;
      final value = draft(focusWhen: () => allowFocus);
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: value.textController(text),
              focusNode: value.focusNode(text),
            ),
          ),
        ),
      );
      final restoring = Future<void>.sync(
        () => value.binding.restore(projection()),
      );
      await tester.pumpAndSettle();
      await restoring;
      expect(
        value.textController(text).selection,
        const TextSelection(baseOffset: 2, extentOffset: 7),
      );
      expect(value.focusNode(text).hasFocus, isTrue);
      await value.binding.restore({...projection(), 'focus': 'none'});
      await tester.pumpAndSettle();
      expect(value.focusNode(text).hasFocus, isFalse);
      expect(value.snapshot()['focus'], 'none');
      final focusedAgain = Future<void>.sync(
        () => value.binding.restore(projection()),
      );
      await tester.pumpAndSettle();
      await focusedAgain;
      value.focusNode(text).unfocus();
      await tester.pumpAndSettle();
      expect(value.snapshot()['focus'], 'comment');
      allowFocus = false;
      expect(value.snapshot()['focus'], 'none');
      value.reset([text]);
      allowFocus = true;
      expect(value.snapshot()['focus'], 'none');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stale async restore cannot overwrite the newer selection and focus',
    (tester) async {
      final waits = <Completer<void>>[];
      final value = draft(
        restoreView: () {
          final done = Completer<void>();
          waits.add(done);
          return done.future;
        },
      );
      addTearDown(value.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: value.textController(text),
              focusNode: value.focusNode(text),
            ),
          ),
        ),
      );
      final old = Future<void>.sync(() => value.binding.restore(projection()));
      final latest = Future<void>.sync(
        () => value.binding.restore({
          ...projection(),
          'comment': 'latest',
          'commentBase': 1,
          'commentExtent': 3,
          'focus': 'none',
        }),
      );
      waits[1].complete();
      await latest;
      waits[0].complete();
      await old;
      await tester.pumpAndSettle();
      expect(value.read(text), 'latest');
      expect(
        value.textController(text).selection,
        const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      expect(value.focusNode(text).hasFocus, isFalse);
      expect(value.snapshot()['focus'], 'none');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'disposing during async restoration cancels later controller access',
    (tester) async {
      final mounted = Completer<void>();
      final value = draft(restoreView: () => mounted.future);
      final pending = Future<void>.sync(
        () => value.binding.restore(projection()),
      );
      value.dispose();
      mounted.complete();
      await pending;
      await tester.pump();
      value.dispose();
      expect(tester.takeException(), isNull);
      expect(() => value.read(id), throwsStateError);
    },
  );

  testWidgets(
    'old projections clamp selection and unknown fields are never captured',
    (tester) async {
      final value = draft();
      addTearDown(value.dispose);
      await value.binding.restore({
        ...projection(),
        'focus': 'none',
        'commentBase': -3,
        'commentExtent': 100,
        'password': 'secret',
      });
      expect(
        value.textController(text).selection,
        const TextSelection(baseOffset: 0, extentOffset: 10),
      );
      expect(value.snapshot().containsKey('password'), isFalse);
      final old = projection()
        ..remove('commentBase')
        ..remove('commentExtent')
        ..remove('focus');
      await value.binding.restore(old);
      expect(
        value.textController(text).selection,
        const TextSelection.collapsed(offset: 0),
      );
    },
  );

  test('field and derived wire keys cannot collide', () {
    for (final fields in <List<DraftField<Object?>>>[
      [id, id],
      [text, DraftField.id('commentBase')],
      [DraftField.id('focus')],
      [DraftField.id('route')],
      [DraftField.id('scrollOffset')],
      [DraftField.text('none', maxLength: 10)],
    ]) {
      expect(
        () => MomentDraft(route: '/x', fields: fields, restoreView: () {}),
        throwsArgumentError,
      );
    }
  });

  testWidgets(
    'binding rejects invalid projection without observing; newer valid revision can recover',
    (tester) async {
      final controller = MomentController(navigate: (_) {});
      addTearDown(controller.dispose);
      final value = draft();
      addTearDown(value.dispose);
      Widget app() => MaterialApp(
        home: MomentScope(
          controller: controller,
          child: Builder(
            builder: (context) {
              value.binding.attach(context, ready: true);
              return const SizedBox();
            },
          ),
        ),
      );
      controller.restore('bad', {
        'name': 'review',
        'projection': {
          ...projection(),
          'scores': {'service': 8},
        },
      });
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(controller.lastError, contains('Invalid draft field: scores'));
      expect(value.read(id), '');
      expect(tester.takeException(), isNull);
      controller.restore('good', {
        'name': 'review',
        'projection': {...projection(), 'focus': 'none'},
      });
      await tester.pumpAndSettle();
      expect(value.read(id), 'one');
      expect(value.read(scores), {'service': 4});
      value.textController(text).text = 'x' * 21;
      expect(controller.lastError, contains('Draft not saved'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
