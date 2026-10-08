/// An explicit, typed field in a Moment's UI projection, not domain data.
sealed class DraftField<T> {
  const DraftField(this.key);
  final String key;
  T get initial;
  T decode(Object? value);

  static DraftField<String> id(String key, {int maxLength = 36}) =>
      _StringField(key, maxLength);
  static TextDraftField text(String key, {required int maxLength}) =>
      TextDraftField(key, maxLength: maxLength);
  static DraftField<String> choice(
    String key, {
    required List<String> values,
    required String initial,
  }) => _ChoiceField(key, List.unmodifiable(values), initial);
  static DraftField<Map<String, int>> ratings(
    String key, {
    required int min,
    required int max,
    required int maxEntries,
    int keyMaxLength = 36,
  }) => _RatingsField(key, min, max, maxEntries, keyMaxLength);
  Never invalid() => throw FormatException('Invalid draft field: $key');
}

final class TextDraftField extends DraftField<String> {
  TextDraftField(super.key, {required this.maxLength}) {
    if (maxLength < 1) throw ArgumentError.value(maxLength, 'maxLength');
  }
  final int maxLength;
  String get baseKey => '${key}Base';
  String get extentKey => '${key}Extent';
  @override
  String get initial => '';
  @override
  String decode(Object? value) =>
      value is String && value.length <= maxLength ? value : invalid();
}

final class _StringField extends DraftField<String> {
  _StringField(super.key, this.maxLength) {
    if (maxLength < 1) throw ArgumentError.value(maxLength, 'maxLength');
  }
  final int maxLength;
  @override
  String get initial => '';
  @override
  String decode(Object? value) =>
      value is String && value.length <= maxLength ? value : invalid();
}

final class _ChoiceField extends DraftField<String> {
  _ChoiceField(super.key, this.values, this.initial) {
    if (values.isEmpty ||
        values.toSet().length != values.length ||
        !values.contains(initial)) {
      throw ArgumentError('Invalid choices for draft field: $key');
    }
  }
  final List<String> values;
  @override
  final String initial;
  @override
  String decode(Object? value) =>
      value is String && values.contains(value) ? value : invalid();
}

final class _RatingsField extends DraftField<Map<String, int>> {
  _RatingsField(
    super.key,
    this.min,
    this.max,
    this.maxEntries,
    this.keyMaxLength,
  ) {
    if (min > max || maxEntries < 1 || keyMaxLength < 1) {
      throw ArgumentError('Invalid bounds for draft field: $key');
    }
  }
  final int min, max, maxEntries, keyMaxLength;
  @override
  Map<String, int> get initial => {};
  @override
  Map<String, int> decode(Object? value) {
    if (value is! Map || value.length > maxEntries) invalid();
    final result = <String, int>{};
    for (final entry in value.entries) {
      final key = entry.key, rating = entry.value;
      if (key is! String ||
          key.length > keyMaxLength ||
          rating is! int ||
          rating < min ||
          rating > max) {
        invalid();
      }
      result[key] = rating;
    }
    return result;
  }
}
