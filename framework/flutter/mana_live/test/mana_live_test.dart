import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_primitives/mana_primitives.dart';
import 'package:mana_live/mana_live.dart';

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('topics match Mana.Entity', () {
    expect(EntityTopics.record('booking', 'b1'), 'entity:booking:b1');
    expect(EntityTopics.audience('booking', 'u1'), 'entity:booking:for:u1');
  });

  test('a burst of changes reloads once after the settle window', () async {
    final changes = StreamController<String>();
    var reloads = 0;
    final live = LiveReload(
      changes.stream,
      () async => reloads++,
      settle: const Duration(milliseconds: 40),
    );
    changes
      ..add('a')
      ..add('b');
    await wait(10);
    changes.add('c');
    await wait(5);
    expect(live.pending, isTrue);
    expect(reloads, 0);
    await wait(80);
    expect(reloads, 1);
    changes.addError(StateError('channel refused'));
    await wait(80);
    expect(reloads, 1);
    await live.dispose();
    changes.add('d');
    await wait(80);
    expect(reloads, 1);
    await changes.close();
  });

  testWidgets(
    'a LiveEntity follows its topics while mounted, through one channel per topic',
    (tester) async {
      final source = FakeChanges();
      var reloads = 0;
      Widget screen(List<String> topics) => ManaLiveScope(
        changes: source,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              LiveEntity(
                topics: topics,
                settle: Duration.zero,
                onChange: () async => reloads++,
                child: const Text('a'),
              ),
              LiveEntity(
                topics: topics,
                settle: Duration.zero,
                onChange: () async => reloads++,
                child: const Text('b'),
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(screen(['entity:booking:b1']));
      expect(source.listeners('entity:booking:b1'), 2);
      source.emit('entity:booking:b1', 'b1');
      await tester.pump(const Duration(milliseconds: 1));
      expect(reloads, 2);

      await tester.pumpWidget(screen(['entity:booking:b2']));
      expect(source.listeners('entity:booking:b1'), 0);
      expect(source.listeners('entity:booking:b2'), 2);

      await tester.pumpWidget(const SizedBox());
      expect(source.listeners('entity:booking:b2'), 0);
    },
  );

  testWidgets('a live view with no record follows the signed-in user', (
    tester,
  ) async {
    final source = FakeChanges();
    final me = ValueNotifier<String?>(null);
    const card = ManaView(
      resource: 'booking',
      name: 'card',
      fields: ['status'],
      live: true,
    );
    await tester.pumpWidget(
      ManaLiveScope(
        changes: source,
        me: me,
        child: LiveEntity.view(
          card,
          onChange: () async {},
          child: const SizedBox(),
        ),
      ),
    );
    expect(source.listeners('entity:booking:for:u1'), 0);

    me.value = 'u1';
    expect(source.listeners('entity:booking:for:u1'), 1);

    me.value = 'u2';
    expect(source.listeners('entity:booking:for:u1'), 0);
    expect(source.listeners('entity:booking:for:u2'), 1);

    await tester.pumpWidget(const SizedBox());
    expect(source.listeners('entity:booking:for:u2'), 0);
    me.dispose();
  });

  test('a live resource follows a record, an audience or its user', () {
    const vehicle = ManaEntity(
      resource: 'vehicle_registration',
      topic: 'vehicle_registration',
      audience: ['traveler_id'],
    );
    expect(
      LiveEntity.of(
        vehicle,
        id: 'v1',
        onChange: () async {},
        child: const SizedBox(),
      ).topics,
      ['entity:vehicle_registration:v1'],
    );
    final mine = LiveEntity.of(
      vehicle,
      onChange: () async {},
      child: const SizedBox(),
    );
    expect(mine.topics, isEmpty);
    expect(mine.mine, ['vehicle_registration']);
  });

  test('a live view follows a record or an audience', () {
    const card = ManaView(
      resource: 'booking',
      name: 'card',
      fields: ['status'],
      live: true,
    );
    final follow = LiveEntity.view(
      card,
      id: 'b1',
      audience: 'u1',
      onChange: () async {},
      child: const SizedBox(),
    );
    expect(follow.topics, ['entity:booking:b1', 'entity:booking:for:u1']);
    const still = ManaView(
      resource: 'booking',
      name: 'still',
      fields: ['status'],
    );
    expect(
      () => LiveEntity.view(
        still,
        id: 'b1',
        onChange: () async {},
        child: const SizedBox(),
      ),
      throwsAssertionError,
    );
  });
}

final class FakeChanges implements EntityChanges {
  final _topics = <String, StreamController<String>>{};
  final _count = <String, int>{};

  @override
  Stream<String> watch(String topic) {
    final source = _topics[topic] ??= StreamController<String>.broadcast();
    late final StreamController<String> out;
    StreamSubscription<String>? sub;
    out = StreamController<String>(
      onListen: () {
        _count[topic] = (_count[topic] ?? 0) + 1;
        sub = source.stream.listen(out.add);
      },
      onCancel: () {
        _count[topic] = _count[topic]! - 1;
        return sub?.cancel();
      },
    );
    return out.stream;
  }

  int listeners(String topic) => _count[topic] ?? 0;

  void emit(String topic, String id) => _topics[topic]?.add(id);
}
