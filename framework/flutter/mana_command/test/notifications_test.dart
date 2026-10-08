import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const _notices = [
  ManaNotification(
    resource: 'booking',
    action: 'request',
    template: 'reservation.requested',
    category: 'reservations',
    channels: ['inbox', 'push', 'email'],
    opens: '/host/operations?booking=:id',
  ),
  ManaNotification(
    resource: 'booking',
    action: 'counter',
    template: 'reservation.proposal_received',
    category: 'reservations',
    channels: ['inbox', 'sms'],
  ),
  ManaNotification(
    resource: 'data_request',
    action: 'reject',
    template: 'data_request.rejected',
    category: 'account',
    channels: ['inbox'],
  ),
];

typedef _Notice = ({String id, String template, bool unread});

void main() {
  test('choices are the declared categories with their outbound channels', () {
    final choices = notificationChoices(_notices);
    expect(choices.map((c) => c.$1), ['reservations']);
    expect(choices.single.$2, ['push', 'email', 'sms']);
  });

  test(
    'the inbox filters by declared category and puts a refused read back',
    () async {
      var refuse = false;
      final inbox = InboxController<_Notice>(
        load: () async => [
          (id: 'a', template: 'reservation.requested', unread: true),
          (id: 'b', template: 'data_request.rejected', unread: true),
        ],
        id: (n) => n.id,
        unread: (n) => n.unread,
        template: (n) => n.template,
        markRead: (id) async {
          if (refuse) throw StateError('refused');
        },
        notices: _notices,
      );
      await inbox.refresh();
      expect(inbox.unreadCount, 2);

      inbox.filterBy('reservations');
      expect(inbox.visible.map((n) => n.id), ['a']);
      expect(
        inbox.link(inbox.visible.single, {'booking_id': 'b1'}),
        '/host/operations?booking=b1',
      );

      expect(await inbox.read(inbox.visible.single), isTrue);
      expect(inbox.unreadCount, 1);

      refuse = true;
      inbox.filterBy(null);
      expect(await inbox.read(inbox.visible.last), isFalse);
      expect(inbox.unreadCount, 1);
    },
  );
}
