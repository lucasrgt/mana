import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_inbox/mana_inbox.dart';

void main() {
  test('ManaInboxController tracks unread counts, deduplicates, and marks read', () {
    final now = DateTime.utc(2026, 11, 24, 18);
    final ctrl = ManaInboxController(
      initial: [
        ManaInboxEntry(
          id: 'n1',
          title: 'PIX recebido',
          detail: 'Studio Norte',
          createdAt: now,
          severity: ManaInboxSeverity.positive,
          unread: true,
        ),
        ManaInboxEntry(
          id: 'n2',
          title: 'Lembrete enviado',
          detail: 'Clínica Vita',
          createdAt: now,
          unread: false,
        ),
      ],
    );

    expect(ctrl.unreadCount, 1);
    ctrl.push(
      ManaInboxEntry(
        id: 'n3',
        title: 'Fatura vencida',
        detail: 'Oficina Alfa',
        createdAt: now,
        severity: ManaInboxSeverity.danger,
        unread: true,
      ),
    );
    expect(ctrl.unreadCount, 2);
    expect(ctrl.entries.first.id, 'n3');

    ctrl.markRead('n1');
    expect(ctrl.unreadCount, 1);

    ctrl.markAllRead();
    expect(ctrl.unreadCount, 0);
    expect(ctrl.hasUnread, isFalse);

    final rt = ManaInboxEntry.fromJson(ctrl.entries.first.toJson());
    expect(rt.id, 'n3');
    expect(rt.severity, ManaInboxSeverity.danger);
  });

  testWidgets('ManaInboxScope rebuilds listeners when entries change', (
    tester,
  ) async {
    final ctrl = ManaInboxController();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ManaInboxScope(
          controller: ctrl,
          child: Builder(
            builder: (ctx) => Text('unread:${ManaInbox.of(ctx).unreadCount}'),
          ),
        ),
      ),
    );
    expect(find.text('unread:0'), findsOneWidget);

    ctrl.push(
      ManaInboxEntry(
        id: 'live-1',
        title: 'Novo pedido',
        detail: '#42',
        createdAt: DateTime.utc(2026, 11, 24),
      ),
    );
    await tester.pump();
    expect(find.text('unread:1'), findsOneWidget);
  });
}
