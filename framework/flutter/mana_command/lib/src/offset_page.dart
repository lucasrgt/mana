/// A counted offset page of an Ash read (`pagination offset?: true,
/// countable: ...`). [OffsetPage.fromAsh] takes the generated client's
/// `response.data.meta?['page']?.value` and refuses a page that does not
/// match the window asked for, so a truncated answer never reads as a page.
/// Offset pages are no snapshot: concurrent writes can shift records.
final class OffsetPage<T> {
  OffsetPage._(this.items, this.offset, this.limit, this.total);

  factory OffsetPage.fromAsh({
    required Iterable<T> items,
    required Object? metadata,
    required int requestedOffset,
    required int requestedLimit,
  }) {
    if (requestedOffset < 0 || requestedLimit < 1 || metadata is! Map) {
      throw const FormatException('Missing or invalid Ash page metadata');
    }
    final offset = metadata['offset'];
    final limit = metadata['limit'];
    final total = metadata['total'];
    if (offset is! int ||
        limit is! int ||
        total is! int ||
        offset != requestedOffset ||
        limit != requestedLimit ||
        total < 0) {
      throw const FormatException(
        'Ash page does not match the requested window',
      );
    }
    final records = List<T>.unmodifiable(items);
    final remaining = total - offset;
    final expected = remaining <= 0
        ? 0
        : (remaining < limit ? remaining : limit);
    if (records.length != expected) {
      throw const FormatException('Inconsistent Ash page count');
    }
    return OffsetPage._(records, offset, limit, total);
  }

  final List<T> items;
  final int offset;
  final int limit;
  final int total;
  bool get hasNext => offset + items.length < total;
  bool get hasPrevious => offset > 0;
}
