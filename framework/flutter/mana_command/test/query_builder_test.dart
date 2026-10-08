import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

void main() {
  testWidgets('keeps the last answer while asking again, unless reset', (
    tester,
  ) async {
    var answer = Completer<List<int>>();
    final query = Query<List<int>>(() => answer.future);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: QueryBuilder<List<int>>(
          query: query,
          loading: (_) => const Text('loading'),
          empty: (_) => const Text('empty'),
          isEmpty: (rows) => rows.isEmpty,
          failure: (_, error, retry) => Text('failed $error'),
          ready: (_, rows) => Text('rows ${rows.length}'),
        ),
      ),
    );
    expect(find.text('loading'), findsOneWidget);

    Future<void> answered(Future<void> asked, void Function() reply) async {
      reply();
      await asked;
      await tester.pump();
    }

    await answered(query.run(), () => answer.complete([1, 2]));
    expect(find.text('rows 2'), findsOneWidget);

    answer = Completer();
    final again = query.run();
    await tester.pump();
    expect(find.text('rows 2'), findsOneWidget);
    await answered(again, () => answer.complete([]));
    expect(find.text('empty'), findsOneWidget);

    query.reset();
    answer = Completer();
    final fresh = query.run();
    await tester.pump();
    expect(find.text('loading'), findsOneWidget);
    await answered(fresh, () => answer.completeError(Exception('down')));
    expect(find.text('failed Exception: down'), findsOneWidget);
    query.dispose();
  });
}
