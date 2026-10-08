import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';
import 'package:mana_primitives/mana_primitives.dart';

const _register = ManaVerb(
  resource: 'vehicle_registration',
  name: 'register',
  action: 'register',
  risk: VerbRisk.none,
  idempotent: false,
  collection: true,
);

const _create = ManaVerb(
  resource: 'property',
  name: 'create',
  action: 'create',
  risk: VerbRisk.none,
  idempotent: false,
  collection: true,
);

void main() {
  test('offers everything until the server first answers', () {
    final available = AvailableVerbs(() async => const []);
    expect(available.loaded, isFalse);
    expect(available.offers(_register), isTrue);
  });

  test('offers what the server answered, by qualified name', () async {
    final available = AvailableVerbs(
      () async => const ['vehicle_registration.register'],
    );
    await available.refresh();
    expect(available.offers(_register), isTrue);
    expect(available.offers(_create), isFalse);
  });

  test('a failed refresh keeps the last answer', () async {
    var fail = false;
    final available = AvailableVerbs(() async {
      if (fail) throw StateError('offline');
      return const ['property.create'];
    });
    await available.refresh();
    fail = true;
    var notified = 0;
    available.addListener(() => notified++);
    await available.refresh();
    expect(available.offers(_create), isTrue);
    expect(notified, 0);
  });
}
