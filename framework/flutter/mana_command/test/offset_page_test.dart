import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

void main() {
  OffsetPage<int> page(
    List<int> items,
    Object? meta, {
    int offset = 0,
    int limit = 2,
  }) => OffsetPage.fromAsh(
    items: items,
    metadata: meta,
    requestedOffset: offset,
    requestedLimit: limit,
  );

  test('a middle page knows both neighbours', () {
    final middle = page(
      [3, 4],
      {'offset': 2, 'limit': 2, 'total': 5},
      offset: 2,
    );
    expect(middle.items, [3, 4]);
    expect(middle.total, 5);
    expect(middle.hasPrevious, isTrue);
    expect(middle.hasNext, isTrue);
  });

  test('the last page may be short and ends the list', () {
    final last = page([5], {'offset': 4, 'limit': 2, 'total': 5}, offset: 4);
    expect(last.hasNext, isFalse);
    expect(() => last.items.add(6), throwsUnsupportedError);
  });

  test('a page that does not match the window asked for is refused', () {
    expect(() => page([1, 2], null), throwsFormatException);
    expect(
      () => page([1, 2], {'offset': 2, 'limit': 2, 'total': 5}),
      throwsFormatException,
    );
    expect(
      () => page([1], {'offset': 0, 'limit': 2, 'total': 5}),
      throwsFormatException,
    );
  });
}
