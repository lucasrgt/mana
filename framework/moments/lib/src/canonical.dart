import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Keys sorted recursively, so equal data digests equally whatever its order.
Object? canonical(Object? value) => switch (value) {
  final List items => items.map(canonical).toList(),
  final Map map => {for (final key in map.keys.cast<String>().toList()..sort()) key: canonical(map[key])},
  _ => value,
};

String hashBytes(List<int> bytes) => sha256.convert(bytes).toString();
String hashText(String text) => sha256.convert(utf8.encode(text)).toString();

/// sha256 of the canonical JSON of [value], as the JS runner's `digest`.
String canonicalDigest(Object? value) => hashText(jsonEncode(canonical(value)));
