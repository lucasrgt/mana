import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const _publish = ManaVerb(
  resource: 'property',
  name: 'publish',
  action: 'publish',
  inverse: 'unpublish',
);
const _unpublish = ManaVerb(
  resource: 'property',
  name: 'unpublish',
  action: 'unpublish',
  inverse: 'publish',
);
const _edit = ManaVerb(resource: 'property', name: 'update', action: 'update');

ManaHistoryEntry _entry(String verb, int minute, {bool failed = false}) =>
    ManaHistoryEntry(
      action: verb,
      summary: verb,
      actor: HistoryActor.user,
      at: DateTime.utc(2026, 10, 8, 12, minute),
      verb: verb,
      failed: failed,
    );

void main() {
  test(
    'only the newest change is undoable, and only while its inverse is offered',
    () {
      final entries = [_entry('publish', 3), _entry('update', 2)];
      final verbs = [_publish, _unpublish, _edit];

      expect(undoable(entries, verbs, ['unpublish'])?.$2, _unpublish);
      expect(undoable(entries, verbs, ['update']), isNull);
      expect(
        undoable([_entry('update', 4), ...entries], verbs, ['unpublish']),
        isNull,
      );
      expect(
        undoable(
          [_entry('unpublish', 5, failed: true), ...entries],
          verbs,
          ['unpublish'],
        )?.$1,
        entries.first,
      );
    },
  );

  testWidgets('undo performs the inverse and reads the history again', (
    tester,
  ) async {
    var entries = [_entry('publish', 3), _entry('update', 2)];
    final performed = <String>[];
    final asked = <ManaHistoryEntry>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: HistoryView(
          load: () async => entries,
          verbs: const [_publish, _unpublish, _edit],
          offered: const ['unpublish'],
          undo: (inverse) async {
            performed.add(inverse.name);
            entries = [_entry('unpublish', 4), ...entries];
          },
          asOf: asked.add,
          entry: (context, entry, undo, asOf) => GestureDetector(
            onTap: undo ?? asOf,
            child: Text('${entry.verb}${undo == null ? '' : ' (undo)'}'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('publish (undo)'), findsOneWidget);

    await tester.tap(find.text('update'));
    expect(asked.single.verb, 'update');

    await tester.tap(find.text('publish (undo)'));
    await tester.pumpAndSettle();
    expect(performed, ['unpublish']);
    expect(find.text('unpublish'), findsOneWidget);
    expect(find.textContaining('(undo)'), findsNothing);
  });
}
