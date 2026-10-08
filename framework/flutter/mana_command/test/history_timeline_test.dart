import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

void main() {
  ManaHistoryEntry entry(String summary, {bool failed = false}) =>
      ManaHistoryEntry(
        action: 'cancel',
        summary: summary,
        actor: HistoryActor.user,
        at: DateTime.utc(2026, 10, 7),
        failed: failed,
      );

  Widget timeline(List<ManaHistoryEntry> entries, {bool showFailed = false}) =>
      Directionality(
        textDirection: TextDirection.ltr,
        child: HistoryTimeline(
          entries: entries,
          showFailed: showFailed,
          empty: const Text('nothing yet'),
          entry: (_, e) => Text(e.summary),
        ),
      );

  testWidgets('shows what happened, hiding failed attempts by default', (
    tester,
  ) async {
    final entries = [entry('cancelled'), entry('tried', failed: true)];
    await tester.pumpWidget(timeline(entries));
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('tried'), findsNothing);

    await tester.pumpWidget(timeline(entries, showFailed: true));
    expect(find.text('tried'), findsOneWidget);

    await tester.pumpWidget(timeline([entry('tried', failed: true)]));
    expect(find.text('nothing yet'), findsOneWidget);
  });
}
