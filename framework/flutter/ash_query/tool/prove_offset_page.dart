import '../lib/ash_query.dart';

void main() {
  OffsetPage<int> page(int offset, int length, Object? metadata) =>
      OffsetPage.fromAsh(
        items: List.generate(length, (i) => i),
        metadata: metadata,
        requestedOffset: offset,
        requestedLimit: 100,
      );
  final first = page(0, 100, {'offset': 0, 'limit': 100, 'total': 125});
  final last = page(100, 25, {'offset': 100, 'limit': 100, 'total': 125});
  if (!first.hasNext ||
      first.hasPrevious ||
      last.hasNext ||
      !last.hasPrevious) {
    throw StateError('Page navigation is inconsistent');
  }
  for (final metadata in [
    null,
    {'offset': 100, 'limit': 100},
    {'offset': 0, 'limit': 100, 'total': 125},
    {'offset': 100, 'limit': 50, 'total': 125},
    {'offset': 100, 'limit': 100, 'total': -1},
    {'offset': 100, 'limit': 100, 'total': 125.5},
    {'offset': 100, 'limit': 100, 'total': 126},
  ]) {
    try {
      page(100, 25, metadata);
    } on FormatException {
      continue;
    }
    throw StateError('Malformed or partial page was accepted');
  }
  final empty = page(0, 0, {'offset': 0, 'limit': 100, 'total': 0});
  if (empty.hasNext || empty.hasPrevious) throw StateError('Empty navigation');
  try {
    first.items.clear();
  } on UnsupportedError {
    print(
      'Ash counted pages: navigation, incomplete responses and immutability verified.',
    );
    return;
  }
  throw StateError('Page records are mutable');
}
