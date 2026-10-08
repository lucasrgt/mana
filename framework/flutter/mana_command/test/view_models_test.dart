import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

final class _Model extends ChangeNotifier {
  _Model(this.name);
  final String name;
  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

void main() {
  test('one per key, replaced on demand, all disposed together', () {
    final models = ViewModels();
    final first = models.of(() => _Model('a'));
    expect(models.of(() => _Model('b')), same(first));
    final keyed = models.of(() => _Model('x'), key: 'x');
    expect(keyed, isNot(same(first)));
    final kept = models.replace(() => _Model('c'), keep: (m) => m.name == 'a');
    expect(kept, same(first));
    final replaced = models.replace(
      () => _Model('c'),
      keep: (m) => m.name == 'z',
    );
    expect(first.disposed, isTrue);
    models.clear();
    expect(replaced.disposed && keyed.disposed, isTrue);
    expect(models.peek<_Model>(), isNull);
  });

  test(
    'a row action reloads after it lands and refuses a second at once',
    () async {
      var reloads = 0;
      final rows = RowAction(reload: () async => reloads++);
      final first = rows.run('a', () => Future<void>.delayed(Duration.zero));
      expect(rows.busy, 'a');
      expect(await rows.run('b', () async {}), isFalse);
      expect(await first, isTrue);
      expect(rows.busy, isNull);
      expect(reloads, 1);
      expect(await rows.run('c', () async => throw Exception('no')), isFalse);
      expect(reloads, 1);
    },
  );
}
