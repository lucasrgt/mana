import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'elixir.dart';
import 'failure.dart';
import 'lab.dart';
import 'manifest.dart';

final _reference = RegExp(r'\b([A-Z][A-Za-z0-9]*)Verbs\.([a-z][A-Za-z0-9]*)\b');
final _generatedMember = RegExp(r'^(all|of|offered|values|byName)$');

/// The verbs each Dart file of [roots] refers to through a generated
/// `XVerbs` class (`BookingVerbs.acceptProposal` → `booking.accept_proposal`),
/// skipping generated code: what `mana graph` hands `mix mana.graph` as the
/// screens.
Map<String, List<String>> screenVerbs(String root, Iterable<String> roots) {
  final found = <String, Set<String>>{};
  for (final frontend in roots) {
    final lib = Directory(p.join(root, frontend, 'lib'));
    if (!lib.existsSync()) {
      continue;
    }
    for (final file in lib.listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.endsWith('.g.dart')) {
        continue;
      }
      final relative = p.relative(file.path, from: root);
      for (final match in _reference.allMatches(file.readAsStringSync())) {
        if (_generatedMember.hasMatch(match[2]!)) {
          continue;
        }
        final verb = '${_snake(match[1]!)}.${_snake(match[2]!)}';
        (found[verb] ??= {}).add(relative);
      }
    }
  }
  return {
    for (final verb in found.keys.toList()..sort())
      verb: found[verb]!.toList()..sort(),
  };
}

String _snake(String name) => name
    .replaceAllMapped(RegExp(r'(?<=[a-z0-9])([A-Z])'), (m) => '_${m[1]}')
    .toLowerCase();

/// `mana graph [query...]`: the backend's `mix mana.graph`, with the screens
/// of every product's frontends.
Future<void> graph(String root, List<String> arguments) async {
  final products = productPaths(root, validate(readManifest(root)));
  final backends = {for (final product in products) ?product.backend};
  if (backends.length != 1) {
    throw ManaFailure(
      'mana graph needs exactly one backend in mana.toml; found ${backends.length}',
    );
  }
  final backend = backends.single;
  final screens = screenVerbs(root, [
    for (final product in products) ...product.frontend,
  ]);
  final file = File(p.join(root, backend, '_build', 'mana-graph-screens.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode(screens));
  final args = [
    'mana.graph',
    ...arguments,
    '--screens',
    p.relative(file.path, from: p.join(root, backend)),
  ];
  // A backend whose runtime config reads the lab's settings needs the lab
  // around it even to read declarations; without a lab database it runs bare.
  bool given(String key) => Platform.environment[key]?.isNotEmpty ?? false;
  try {
    if (given('MANA_LAB_POSTGRES') || given('MANA_MOMENTS_INSTANCE')) {
      await lab(root, ['mix', ...args], backend: backend);
    } else {
      await mix(p.join(root, backend), args);
    }
  } finally {
    if (file.existsSync()) file.deleteSync();
  }
}
