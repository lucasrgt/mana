import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_assistant/mana_assistant.dart';

void main() {
  test('ManaAssistantController manages threads, auto-titling, and resolution', () async {
    final ctrl = ManaAssistantController(defaultThreadTitle: 'Nova conversa');
    expect(ctrl.historyThreads, isEmpty);

    await ctrl.send(
      'Quem está em atraso agora?',
      resolver: (prompt, replyId, threadId) async => ManaChatTurn(
        id: replyId,
        isUser: false,
        text: '1 fatura em atraso.',
        createdAt: DateTime.utc(2026, 11, 24),
        toolTraces: const [
          ManaToolTrace(label: 'Cobranças em atraso', resultLabel: '1'),
        ],
        intents: const [
          ManaAssistantIntent(
            id: 'act-1',
            label: 'Enviar lembrete',
            actionKey: 'send_reminder',
            primary: true,
          ),
        ],
      ),
    );

    expect(ctrl.activeThread.title, 'Quem está em atraso agora?');
    expect(ctrl.activeTurns.length, 2);
    expect(ctrl.activeTurns.last.thinking, isFalse);
    expect(ctrl.historyThreads.length, 1);

    ctrl.markIntentCompleted(ctrl.activeTurns.last.id, 'act-1');
    expect(ctrl.activeTurns.last.intents.first.completed, isTrue);

    final firstId = ctrl.activeThreadId;
    final second = ctrl.startNewThread();
    expect(second.id, isNot(firstId));
    expect(ctrl.activeTurns, isEmpty);

    ctrl.selectThread(firstId);
    expect(ctrl.activeTurns.length, 2);
  });

  testWidgets('ManaAssistantScope notifies descendants on state changes', (
    tester,
  ) async {
    final ctrl = ManaAssistantController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ManaAssistantScope(
          controller: ctrl,
          child: Builder(
            builder: (ctx) => Text('rec:${ManaAssistant.of(ctx).isRecording}'),
          ),
        ),
      ),
    );
    expect(find.text('rec:false'), findsOneWidget);

    ctrl.setRecording(true);
    await tester.pump();
    expect(find.text('rec:true'), findsOneWidget);
  });
}
