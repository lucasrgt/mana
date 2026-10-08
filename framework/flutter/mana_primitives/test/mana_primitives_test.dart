import 'package:mana_primitives/mana_primitives.dart';
import 'package:test/test.dart';

void main() {
  const cancel = ManaVerb(
    resource: 'booking',
    name: 'cancel',
    action: 'cancel',
    risk: VerbRisk.money,
  );

  test('a verb is offered only when the record lists it', () {
    expect(cancel.offeredBy(['accept', 'cancel']), isTrue);
    expect(cancel.offeredBy(['accept']), isFalse);
    expect(cancel.offeredBy(null), isFalse);
  });

  test('risk parses the contract value and decides confirmation', () {
    expect(VerbRisk.parse('money'), VerbRisk.money);
    expect(VerbRisk.parse('unknown'), VerbRisk.none);
    expect(cancel.risk.confirms, isTrue);
    expect(VerbRisk.none.confirms, isFalse);
    expect('$cancel', 'booking.cancel');
  });

  test('a view asks for only its fields', () {
    const view = ManaView(
      resource: 'booking',
      name: 'card',
      fields: ['status', 'verbs'],
      live: true,
    );
    expect(view.sparse, {'booking': 'status,verbs'});
    expect('$view', 'booking:card');
  });

  test('an attachment rejects what the server would refuse', () {
    const cover = ManaAttachment(
      resource: 'property',
      attribute: 'cover_photo_id',
      kinds: [
        AttachmentKind(
          name: 'property_photo',
          accept: ['image/jpeg', 'image/png'],
          maxBytes: 10,
        ),
      ],
    );
    expect(cover.kind.name, 'property_photo');
    expect(cover.reject(contentType: 'image/png', sizeBytes: 10), isNull);
    expect(
      cover.reject(contentType: 'application/pdf', sizeBytes: 3),
      'upload.content_type_invalid',
    );
    expect(
      cover.reject(contentType: 'image/png', sizeBytes: 11),
      'upload.size_too_large',
    );
    expect(
      cover.reject(contentType: 'image/png', sizeBytes: 0),
      'upload.size_too_large',
    );
    expect(cover.toString(), 'property.cover_photo_id');
  });

  test('a verb input refuses what the server would refuse', () {
    const title = VerbInput(
      name: 'title',
      type: 'string',
      required: true,
      minLength: 3,
      maxLength: 5,
      match: '^[a-z]',
    );
    expect(title.check(null), 'required');
    expect(title.check('  '), 'required');
    expect(title.check('ab'), 'too_short');
    expect(title.check('abcdef'), 'too_long');
    expect(title.check('Abc'), 'pattern');
    expect(title.check('abc'), isNull);
    expect(title.check(3), 'type');

    const copies = VerbInput(name: 'copies', type: 'integer', min: 1, max: 5);
    expect(copies.check(null), isNull);
    expect(copies.check('2'), isNull);
    expect(copies.check('x'), 'type');
    expect(copies.check(1.5), 'type');
    expect(copies.check(0), 'too_small');
    expect(copies.check(6), 'too_large');

    const tags = VerbInput(
      name: 'tags',
      type: 'array',
      maxLength: 2,
      items: VerbInput(name: 'tags', type: 'string', oneOf: ['bug', 'idea']),
    );
    expect(tags.check(['bug']), isNull);
    expect(tags.check(['bug', 'idea', 'bug']), 'too_long');
    expect(tags.check(['other']), 'one_of');
    expect(tags.check('bug'), 'type');

    const cpf = VerbInput(name: 'cpf', type: 'string', format: 'br-cpf');
    expect(cpf.check('123'), isNull);
    expect(
      cpf.check('123', formats: {'br-cpf': (v) => v.length == 11}),
      'format',
    );
    const id = VerbInput(name: 'id', type: 'string', format: 'uuid');
    expect(id.check('nope'), 'format');
    expect(id.check('6f1c2a0e-1b2c-4d3e-8f90-123456789abc'), isNull);
    expect(const VerbInput(name: 'ok', type: 'boolean').check('yes'), 'type');
    const slot = VerbInput(name: 'slot', type: 'string', format: 'date-time');
    expect(slot.check(DateTime(2026)), isNull);
    expect(slot.check('2026-10-07T10:00:00Z'), isNull);
    expect(slot.check('tomorrow'), 'format');
    expect(title.check(DateTime(2026)), 'type');

    const verb = ManaVerb(
      resource: 'ticket',
      name: 'rename',
      action: 'rename',
      inputs: [title, copies],
    );
    expect(verb.input('copies'), same(copies));
    expect(() => verb.input('missing'), throwsArgumentError);
    expect(title.toString(), 'title');
  });

  test('server errors land on the input they point at', () {
    expect(
      verbFieldErrors({
        'errors': [
          {
            'code': 'invalid_attribute',
            'source': {'pointer': '/data/attributes/title'},
          },
          {'code': 'operations.slot_taken', 'field': 'scheduled_for'},
          {
            'source': {'pointer': '/data/arguments/reason'},
          },
          {'code': 'forbidden'},
          {
            'source': {'pointer': '/data'},
          },
        ],
      }),
      {
        'title': 'invalid_attribute',
        'scheduled_for': 'operations.slot_taken',
        'reason': 'invalid',
      },
    );
    expect(verbFieldErrors('oops'), isEmpty);
  });

  test('a history entry reads as the log serves it', () {
    final entry = ManaHistoryEntry.fromJson({
      'action': 'cancel',
      'verb': 'cancel',
      'summary': 'cancelled the booking',
      'actor_kind': 'agent',
      'via': 'planner',
      'actor_id': null,
      'at': '2026-10-07T10:00:00Z',
      'outcome': 'failed',
      'error': 'forbidden',
      'params': {'reason': 'other'},
      'before': {'status': 'paid'},
      'after': {'status': 'cancelled', 'cancelled_at': '2026-10-07'},
    });
    expect(entry.actor, HistoryActor.agent);
    expect(entry.failed, isTrue);
    expect(entry.at, DateTime.utc(2026, 10, 7, 10));
    expect(entry.changes, {
      'status': ('paid', 'cancelled'),
      'cancelled_at': (null, '2026-10-07'),
    });
    final quiet = ManaHistoryEntry.fromJson({
      'action': 'create',
      'summary': 'create',
      'actor_kind': 'user',
      'at': '2026-10-07T10:00:00Z',
      'outcome': 'done',
    });
    expect(quiet.failed, isFalse);
    expect(quiet.changes, isEmpty);
    const history = ManaHistory(resource: 'booking', log: 'history_entry');
    expect(history.redacted, isEmpty);
  });

  test('a flow says where a record stands', () {
    const flow = ManaFlow(
      resource: 'host',
      cursor: 'lifecycle_state',
      done: 'complete',
      steps: [
        FlowStep(name: 'terms', action: 'advance_terms'),
        FlowStep(name: 'details', action: 'save_details', optional: true),
        FlowStep(name: 'address', action: 'save_address', skippable: true),
        FlowStep(name: 'languages', action: 'save_languages'),
      ],
    );
    expect(flow.stepOf('details')?.action, 'save_details');
    expect(flow.stepOf('complete'), isNull);
    expect(flow.indexOf('address'), 2);
    expect(flow.progress('address'), 0.5);
    expect(flow.indexOf('review_demo'), 0);
    expect(flow.isDone('complete'), isTrue);
    expect(flow.progress('complete'), 1);
    expect(
      const ManaFlow(
        resource: 'x',
        cursor: 'c',
        done: 'd',
        steps: [],
      ).progress(null),
      1,
    );
  });

  test('a notice links to the record its payload names', () {
    const confirmed = ManaNotification(
      resource: 'booking',
      action: 'accept',
      template: 'reservation.confirmed',
      category: 'reservations',
      opens: '/traveler/reservations?booking=:id',
    );
    const cancelled = ManaNotification(
      resource: 'booking',
      action: 'cancel',
      template: 'reservation.cancelled',
    );
    expect(
      confirmed.link({'booking_id': 'b 1'}),
      '/traveler/reservations?booking=b%201',
    );
    expect(confirmed.link({'chat_id': 'c'}), isNull);
    expect(cancelled.link({'booking_id': 'b1'}), isNull);
    expect(
      ManaNotification.of([confirmed, cancelled], 'reservation.cancelled'),
      same(cancelled),
    );
    expect(ManaNotification.of([confirmed], 'other'), isNull);
    expect(cancelled.channels, ['inbox']);
  });

  test('a collection verb is offered under its qualified name', () {
    const request = ManaVerb(
      resource: 'booking',
      name: 'request',
      action: 'request',
      collection: true,
      from: 'service',
    );
    const accept = ManaVerb(
      resource: 'booking',
      name: 'accept',
      action: 'accept',
    );
    expect(request.qualified, 'booking.request');
    expect(request.offeredBy(['publish', 'booking.request']), isTrue);
    expect(request.offeredBy(['request']), isFalse);
    expect(accept.offeredBy(['accept']), isTrue);
  });

  test(
    'an operation matches its route and takes the strictest rule of its verbs',
    () {
      const read = ManaVerb(
        resource: 'notification',
        name: 'mark_read',
        action: 'mark_read',
        idempotent: true,
        retry: 2,
        offline: VerbOffline.queue,
      );
      const accept = ManaVerb(
        resource: 'booking',
        name: 'accept',
        action: 'accept',
      );
      const marking = ManaOperation(
        method: 'PATCH',
        path: '/api/notifications/{id}/read',
        verbs: [read],
      );
      const both = ManaOperation(
        method: 'PATCH',
        path: '/api/x/{id}',
        verbs: [read, accept],
      );

      expect(
        marking.matches('patch', '/api/notifications/n1/read?x=1'),
        isTrue,
      );
      expect(marking.matches('PATCH', '/api/notifications/n1'), isFalse);
      expect(marking.matches('GET', '/api/notifications/n1/read'), isFalse);
      expect(
        ManaOperation.of([both, marking], 'PATCH', '/api/notifications/9/read'),
        same(marking),
      );
      expect((marking.retry, marking.queues), (2, true));
      expect((both.retry, both.queues), (0, false));
    },
  );
}
