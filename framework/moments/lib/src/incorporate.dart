import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'bridge.dart' show validateOverrides;
import 'errors.dart';
import 'json.dart';
import 'live_source.dart';

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();
String _read(String path) => File(path).readAsStringSync();
final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');
final _pretty = const JsonEncoder.withIndent('  ');

/// Replacements that turn the saved live overrides into source defaults,
/// computed only from the app's trusted target mapping.
Map<String, Object?> planIncorporation(String project, {String? prefix}) {
  if (prefix != null && !RegExp(r'^[a-z][a-z0-9_.-]*\.$').hasMatch(prefix)) {
    throw const MomentsError('Expected a property prefix ending in a dot, e.g. reviews.');
  }
  final directory = p.join(project, 'live-ui');
  final inputs = {
    for (final name in ['schema.json', 'targets.json', 'overrides.json']) name: _read(p.join(directory, name)),
  };
  final schema = asObject(jsonDecode(inputs['schema.json']!));
  final targets = asObject(jsonDecode(inputs['targets.json']!));
  final saved = asObject(jsonDecode(inputs['overrides.json']!));
  if (saved['version'] != 1) throw const MomentsError('Unsupported overrides version');
  validateOverrides(saved['values'], schema);
  if (prefix != null && !schema.keys.any((key) => key.startsWith(prefix))) {
    throw MomentsError('Unknown property prefix: $prefix');
  }
  final files = <String, Map<String, String>>{};
  final changes = <Map<String, Object?>>[];
  final values = asObject(saved['values']).entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  for (final MapEntry(:key, :value) in values) {
    if (value == null || (prefix != null && !key.startsWith(prefix))) continue;
    final target = (targets[key] as Map?)?.cast<String, Object?>();
    if (target == null) throw MomentsError('No incorporation target for $key');
    final file = target['file']! as String;
    final path = sourcePath(project, file);
    final entry = files[path] ?? {'file': file, 'before': _read(path), 'after': _read(path)};
    final RegExp expression;
    final String replacement;
    value as String;
    if (target['kind'] == 'arb') {
      final arbKey = target['key'];
      if (arbKey is! String || !_identifier.hasMatch(arbKey) || !file.endsWith('.arb')) {
        throw MomentsError('Invalid ARB target: $key');
      }
      // These are literal labels, not ICU messages with arguments.
      if (RegExp('[{}]').hasMatch(value))
        throw MomentsError('$key: ICU placeholders need an explicit localization edit');
      final content = asObject(jsonDecode(entry['after']!));
      if (content[arbKey] is! String || (content['@$arbKey'] as Map?)?['placeholders'] != null) {
        throw MomentsError('Not a literal ARB label: $key');
      }
      expression = RegExp('("${RegExp.escape(arbKey)}"\\s*:\\s*)"(?:[^"\\\\]|\\\\.)*"');
      replacement = jsonEncode(value);
    } else if (target['kind'] == 'dartEnum') {
      final symbol = target['symbol'], type = target['type'];
      final allowed = (schema[key] as Map?)?['enum'] as List?;
      if (!file.endsWith('.dart') ||
          symbol is! String ||
          !_identifier.hasMatch(symbol) ||
          type is! String ||
          !_identifier.hasMatch(type) ||
          !_identifier.hasMatch(value) ||
          !(allowed?.contains(value) ?? false)) {
        throw MomentsError('Invalid Dart enum target: $key');
      }
      expression = RegExp(
        '(^[\\t ]*const ${RegExp.escape(symbol)}\\s*=\\s*)${RegExp.escape(type)}\\.[A-Za-z][A-Za-z0-9_]*\\s*;',
        multiLine: true,
      );
      replacement = '$type.$value;';
    } else {
      throw MomentsError('Unsupported target kind: $key');
    }
    final matches = expression.allMatches(entry['after']!).toList();
    if (matches.length != 1) {
      throw MomentsError('Expected exactly one source binding for $key; found ${matches.length}');
    }
    final beforeValue = matches.single[0]!.substring(matches.single[1]!.length);
    entry['after'] = entry['after']!.replaceAllMapped(expression, (match) => '${match[1]}$replacement');
    files[path] = entry;
    if (beforeValue != replacement)
      changes.add({'property': key, 'file': file, 'from': beforeValue, 'to': replacement});
  }
  return {
    'version': 1,
    'prefix': prefix,
    'inputHashes': {for (final MapEntry(:key, :value) in inputs.entries) key: _digest(value)},
    'files': [
      for (final file in files.values)
        if (file['before'] != file['after']) file,
    ],
    'changes': changes,
  };
}

Map<String, Object?> savePlan(String project, {String? prefix}) {
  final plan = planIncorporation(project, prefix: prefix);
  final file = File(p.join(project, 'live-ui/.incorporate-plan.json'));
  file.writeAsStringSync('${_pretty.convert(plan)}\n');
  Process.runSync('chmod', ['600', file.path]);
  return plan;
}

Map<String, Object?> applyPlan(String project, {String? prefix}) {
  final saved = jsonDecode(_read(p.join(project, 'live-ui/.incorporate-plan.json')));
  final current = planIncorporation(project, prefix: prefix);
  // Recompute from the trusted mapping instead of executing paths in a plan.
  if (jsonEncode(saved) != jsonEncode(current)) {
    throw const MomentsError('Source or preview changed since planning. Run incorporate again to review a fresh plan.');
  }
  final written = <(String, Map)>[];
  final planned = (current['files']! as List).cast<Map>();
  try {
    for (final file in planned) {
      final path = sourcePath(project, file['file']);
      if (_read(path) != file['before']) throw MomentsError('Source changed: ${file['file']}');
      final temp = '$path.live-ui.tmp';
      File(temp)
        ..createSync(exclusive: true)
        ..writeAsStringSync(file['after']! as String);
      File(temp).renameSync(path);
      written.add((path, file));
    }
  } on Object {
    for (final (path, file) in written.reversed) {
      if (_read(path) == file['after']) File(path).writeAsStringSync(file['before']! as String);
    }
    rethrow;
  }
  // Keep overrides: a running client still has the old compiled defaults.
  return {
    'written': [for (final file in planned) file['file']],
    'previewRetained': true,
    'next': prefix != null
        ? 'Run flutter gen-l10n, rebuild/reload, then clear only $prefix* previews with patch null to verify the incorporated defaults.'
        : 'Run flutter gen-l10n, rebuild/reload, then reset the preview to verify the incorporated defaults.',
  };
}
