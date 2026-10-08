import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

final class Offline implements Exception {}

final class Flaky implements Exception {}

void main() {
  const read = ManaVerb(
    resource: 'notification',
    name: 'mark_read',
    action: 'mark_read',
    idempotent: true,
    retry: 2,
    offline: VerbOffline.queue,
  );
  const pay = ManaVerb(
    resource: 'booking',
    name: 'pay',
    action: 'pay',
    risk: VerbRisk.money,
  );

  late List<String> sent;
  late List<Object?> failures;

  VerbRunner runner({VerbQueueStore? store}) => VerbRunner(
    verbs: const [read, pay],
    store: store,
    isOffline: (e) => e is Offline,
    isTransient: (e) => e is Flaky || e is Offline,
    backoff: (_) => Duration.zero,
    send: (verb, id, params) async {
      final failure = failures.isEmpty ? null : failures.removeAt(0);
      if (failure != null) throw failure;
      sent.add('${verb.name}:$id:${params['at'] ?? ''}');
    },
  );

  setUp(() {
    sent = [];
    failures = [];
  });

  test(
    'a transient failure is resent as many times as the verb allows',
    () async {
      final verbs = runner();
      failures = [Flaky(), Flaky()];
      expect(await verbs.run(read, 'n1'), VerbOutcome.done);
      expect(sent, ['mark_read:n1:']);

      failures = [Flaky(), Flaky(), Flaky()];
      expect(await verbs.run(read, 'n2'), VerbOutcome.failed);
      expect(verbs.stateOf(read, 'n2'), VerbRunState.failed);
      expect(verbs.errorOf(read, 'n2'), isA<Flaky>());
    },
  );

  test(
    'offline, a queueing verb waits once per record and survives a restart',
    () async {
      final store = MemoryVerbQueueStore();
      final verbs = runner(store: store);
      failures = [Offline(), Offline()];
      expect(await verbs.run(read, 'n1', {'at': 1}), VerbOutcome.queued);
      expect(await verbs.run(read, 'n1', {'at': 2}), VerbOutcome.queued);
      expect(verbs.queued.single.params, {'at': 2});
      expect(verbs.stateOf(read, 'n1'), VerbRunState.queued);

      final restarted = runner(store: store);
      await restarted.restore();
      expect(restarted.stateOf(read, 'n1'), VerbRunState.queued);
      failures = [Offline()];
      expect(await restarted.flush(), 0);
      expect(restarted.queued, hasLength(1));
      expect(await restarted.flush(), 1);
      expect(sent, ['mark_read:n1:2']);
      expect(restarted.queued, isEmpty);
      expect(restarted.stateOf(read, 'n1'), VerbRunState.idle);
      expect(await store.load(), isEmpty);
    },
  );

  test(
    'a verb that cannot queue fails at once offline, and money never waits',
    () async {
      final verbs = runner();
      failures = [Offline()];
      expect(await verbs.run(pay, 'b1'), VerbOutcome.failed);
      expect(verbs.queued, isEmpty);
      expect(sent, isEmpty);
    },
  );

  test(
    'a queued verb the server now refuses is dropped and shown failed',
    () async {
      final verbs = runner();
      failures = [Offline(), StateError('gone')];
      await verbs.run(read, 'n1');
      expect(await verbs.flush(), 0);
      expect(verbs.queued, isEmpty);
      expect(verbs.stateOf(read, 'n1'), VerbRunState.failed);
    },
  );

  test('a string slot keeps the queue as JSON and tolerates garbage', () async {
    String? slot = 'not json';
    final store = StringVerbQueueStore(
      read: () async => slot,
      write: (value) async => slot = value,
    );
    expect(await store.load(), isEmpty);
    final item = QueuedVerb(
      resource: 'notification',
      verb: 'mark_read',
      recordId: 'n1',
      queuedAt: DateTime.utc(2026, 10, 7),
      params: const {'a': 1},
    );
    await store.save([item]);
    final loaded = (await store.load()).single;
    expect(loaded.sameAs(item), isTrue);
    expect(loaded.params, {'a': 1});
    expect(loaded.queuedAt, DateTime.utc(2026, 10, 7));
    slot = null;
    expect(await store.load(), isEmpty);
  });

  test(
    'a restored entry naming a verb no longer declared is dropped',
    () async {
      final store = MemoryVerbQueueStore();
      await store.save([
        QueuedVerb(
          resource: 'notification',
          verb: 'archived',
          recordId: 'n9',
          queuedAt: DateTime.utc(2026),
        ),
      ]);
      final verbs = runner(store: store);
      await verbs.restore();
      expect(await verbs.flush(), 0);
      expect(verbs.queued, isEmpty);
    },
  );
}
