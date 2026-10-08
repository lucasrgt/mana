import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

void main() {
  test(
    'the latest request wins and the last answer stays while asking',
    () async {
      final answers = <Completer<String>>[];
      final query = Query<String>(() {
        final answer = Completer<String>();
        answers.add(answer);
        return answer.future;
      });

      final slow = query.run();
      final fast = query.run();
      answers[1].complete('new');
      await fast;
      answers[0].complete('old');
      await slow;
      expect(query.value, isA<SuccessCommand<String>>());
      expect((query.value as SuccessCommand<String>).value, 'new');

      final again = query.run();
      expect(query.value.isRunning, isTrue);
      expect(query.last, 'new');
      answers[2].completeError(Exception('down'));
      await again;
      expect(query.value.isFailure, isTrue);
      expect(query.last, 'new');

      query.reset();
      expect(query.value.isIdle, isTrue);
      expect(query.last, isNull);
    },
  );

  test('an answer arriving after dispose is dropped', () async {
    final answer = Completer<String>();
    final query = Query<String>(() => answer.future);
    final running = query.run();
    query.dispose();
    answer.complete('late');
    await running;
  });
}
