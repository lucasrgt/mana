import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';

typedef Capability = ({
  String id,
  String name,
  String layer,
  String status,
  String summary,
  String use,
  List<String> replaces,
  List<String> keywords,
  String? detector,
  String docs,
});

const _layers = ['coordinate', 'core', 'primitive', 'verification'];
const _layerTitles = {
  'coordinate': 'Coordinates — shared addresses',
  'core': 'Core',
  'primitive': 'Primitives',
  'verification': 'Verification',
};

/// The framework catalog (`framework/catalog.toml`): every piece, how to use
/// it and what it replaces.
final class Catalog {
  Catalog._(this.capabilities);

  final List<Capability> capabilities;

  static Catalog load(String framework) {
    final file = p.join(framework, 'catalog.toml');
    final Map<String, Object?> data;
    try {
      data = TomlDocument.parse(File(file).readAsStringSync()).toMap();
    } on TomlException catch (error) {
      throw ManaFailure('Invalid catalog.toml: $error');
    } on FileSystemException {
      throw ManaFailure('Missing $file');
    }
    if (data['version'] != 1) {
      throw const ManaFailure('Unsupported catalog.toml version');
    }
    final entries = data['capability'];
    if (entries is! List || entries.isEmpty) {
      throw const ManaFailure('catalog.toml declares no capability');
    }
    final ids = <String>{};
    final capabilities = <Capability>[];
    for (final entry in entries) {
      if (entry is! Map) {
        throw const ManaFailure('Each capability must be a table');
      }
      String text(String key) {
        final value = entry[key];
        if (value is! String || value.trim().isEmpty) {
          throw ManaFailure('capability ${entry['id']}: missing $key');
        }
        return value;
      }

      final replaces = entry['replaces'] ?? const <String>[];
      if (replaces is! List || replaces.any((r) => r is! String)) {
        throw ManaFailure(
          'capability ${entry['id']}: replaces must be a list of strings',
        );
      }
      final capability = (
        id: text('id'),
        name: text('name'),
        layer: text('layer'),
        status: text('status'),
        summary: text('summary'),
        use: text('use'),
        replaces: replaces.cast<String>(),
        keywords: ((entry['keywords'] ?? const <String>[]) as List)
            .cast<String>(),
        detector: entry['detector'] as String?,
        docs: text('docs'),
      );
      if (!_layers.contains(capability.layer)) {
        throw ManaFailure('capability ${capability.id}: unknown layer');
      }
      if (!const ['available', 'planned'].contains(capability.status)) {
        throw ManaFailure(
          'capability ${capability.id}: status must be available or planned',
        );
      }
      if (!ids.add(capability.id)) {
        throw ManaFailure('Duplicate capability ${capability.id}');
      }
      capabilities.add(capability);
    }
    return Catalog._(capabilities);
  }

  /// Capabilities matching any word of [query], best match first. Words are
  /// compared without accents, so Portuguese and English queries both work.
  List<Capability> search(String? query, {bool all = false}) {
    final words = _terms(query ?? '');
    final scored = <(Capability, int)>[];
    for (final c in capabilities) {
      if (!all && c.status != 'available') continue;
      final named = _terms([c.id, c.name, ...c.keywords].join(' ')).toSet();
      final told = _terms([c.summary, c.use, ...c.replaces].join(' ')).toSet();
      final score = words.fold(
        0,
        (sum, w) =>
            sum + (named.contains(w) ? 3 : 0) + (told.contains(w) ? 1 : 0),
      );
      if (words.isEmpty || score > 0) scored.add((c, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return [for (final (c, _) in scored) c];
  }

  static const _stopwords = {
    'de',
    'do',
    'da',
    'dos',
    'das',
    'ao',
    'aos',
    'no',
    'na',
    'nos',
    'nas',
    'um',
    'uma',
    'com',
    'em',
    'para',
    'por',
    'que',
    'se',
    'the',
    'and',
    'to',
    'of',
    'in',
    'on',
    'for',
    'with',
  };

  static const _suffixes = [
    'coes',
    'cao',
    'mente',
    'ar',
    'er',
    'ir',
    'os',
    'as',
    'es',
    'o',
    'a',
    'e',
    's',
  ];

  /// Folded, stemmed words: `anexar`, `anexo` and `anexos` meet at `anex`.
  static List<String> _terms(String text) => [
    for (final word in _fold(text).split(RegExp(r'[^a-z0-9]+')))
      if (word.length > 1 && !_stopwords.contains(word)) _stem(word),
  ];

  static String _stem(String word) {
    for (final suffix in _suffixes) {
      if (word.endsWith(suffix) && word.length - suffix.length >= 4) {
        return word.substring(0, word.length - suffix.length);
      }
    }
    return word;
  }

  static String _fold(String text) {
    const from = 'áàâãäéèêëíìîïóòôõöúùûüçñ';
    const to = 'aaaaaeeeeiiiiooooouuuucn';
    final lower = text.toLowerCase();
    final out = StringBuffer();
    for (final rune in lower.runes) {
      final char = String.fromCharCode(rune);
      final index = from.indexOf(char);
      out.write(index < 0 ? char : to[index]);
    }
    return out.toString();
  }

  static Map<String, Object?> json(Capability c) => {
    'id': c.id,
    'name': c.name,
    'layer': c.layer,
    'status': c.status,
    'summary': c.summary,
    'use': c.use,
    'replaces': c.replaces,
    'keywords': c.keywords,
    'detector': ?c.detector,
    'docs': c.docs,
  };

  static String text(Capability c) => [
    '${c.name} [${c.id}]${c.status == 'planned' ? ' (planned)' : ''}',
    '  ${c.summary}',
    '  Use: ${c.use}',
    if (c.replaces.isNotEmpty) '  Instead of: ${c.replaces.join('; ')}',
    if (c.detector != null) '  Enforced by: ${c.detector}',
    '  Docs: ${c.docs}',
  ].join('\n');

  /// The agent skill, generated so it cannot drift from the catalog.
  String skill() {
    final out = StringBuffer()
      ..writeln('---')
      ..writeln('name: mana')
      ..writeln(
        'description: The Mana framework as one system. Use before writing any backend, Flutter or test code in a '
        'Mana project: find the existing capability (mana capabilities <topic>), the feature that owns the files '
        '(mana features which), and the Moments that prove it, instead of re-deriving or reimplementing them.',
      )
      ..writeln('---')
      ..writeln()
      ..writeln(
        '<!-- Generated from framework/catalog.toml by `mana capabilities skill`. Edit the catalog. -->',
      )
      ..writeln()
      ..writeln('# Mana — one framework')
      ..writeln()
      ..writeln(
        'Mana is not a set of loose libraries. Every piece below is part of one system: the product declares '
        'intent once in Ash, and Mana derives the API, the Dart client, the Flutter halves, the Moments and the '
        'verification. Reimplementing a piece by hand is a defect even when it works.',
      )
      ..writeln()
      ..writeln('## Before you write code')
      ..writeln()
      ..writeln(
        '1. `framework/cli/mana capabilities <topic>` — does Mana already do this? Use it.',
      )
      ..writeln(
        '2. `framework/cli/mana features which <path>` — which feature owns the file; '
        '`mana features show <feature>` lists its files and Moments.',
      )
      ..writeln(
        '3. Change the Ash resource first; regenerate the client (`mana client generate`); then the Flutter half.',
      )
      ..writeln(
        '4. Prove it with the feature\'s Moments (`framework/moments/moments check|run <name>`); read the AVP '
        'verdict, never only the exit code.',
      )
      ..writeln(
        '5. `dart analyze` at the package root (Mana lints) and `framework/cli/mana doctor` before finishing.',
      )
      ..writeln();
    for (final layer in _layers) {
      final items = capabilities
          .where((c) => c.layer == layer && c.status == 'available')
          .toList();
      if (items.isEmpty) continue;
      out
        ..writeln('## ${_layerTitles[layer]}')
        ..writeln();
      for (final c in items) {
        out
          ..writeln('### ${c.name} (`${c.id}`)')
          ..writeln()
          ..writeln(c.summary)
          ..writeln()
          ..writeln('- **Use:** ${c.use}');
        if (c.replaces.isNotEmpty) {
          out.writeln('- **Instead of:** ${c.replaces.join('; ')}');
        }
        if (c.detector != null) out.writeln('- **Enforced by:** ${c.detector}');
        out
          ..writeln('- **Docs:** `${c.docs}`')
          ..writeln();
      }
    }
    final planned = capabilities.where((c) => c.status == 'planned').toList();
    if (planned.isNotEmpty) {
      out
        ..writeln('## Planned (not available yet)')
        ..writeln()
        ..writeln(
          'Do not build these by hand while they are planned; follow the current guidance in each line.',
        )
        ..writeln();
      for (final c in planned) {
        out.writeln('- **${c.name}** (`${c.id}`): ${c.summary} ${c.use}');
      }
    }
    return out.toString();
  }
}
