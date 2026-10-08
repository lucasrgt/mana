import 'dart:convert';

/// Equality the JS runner used: identical JSON text, key order included.
bool jsonEqual(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

/// Structural equality ignoring map key order, as Node's `isDeepStrictEqual`
/// on plain JSON data.
bool deepEqual(Object? a, Object? b) => jsonEqual(_sorted(a), _sorted(b));

Object? _sorted(Object? value) => switch (value) {
  final List items => items.map(_sorted).toList(),
  final Map map => {for (final key in map.keys.map((k) => '$k').toList()..sort()) key: _sorted(map[key])},
  _ => value,
};

/// A deep copy through JSON, as `structuredClone` of plain data.
T jsonCopy<T>(T value) => jsonDecode(jsonEncode(value)) as T;

bool isObject(Object? value) => value is Map;

Map<String, Object?> asObject(Object? value) => (value as Map).cast<String, Object?>();

/// Milliseconds on a monotonic clock, as `performance.now()`.
final _clock = Stopwatch()..start();
double nowMs() => _clock.elapsedMicroseconds / 1000;
