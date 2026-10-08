import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

/// Only explicitly mapped, existing files inside this app's lib/ are writable.
String sourcePath(String project, Object? file) {
  if (file is! String || !file.startsWith('lib/')) throw const MomentsError('Target must be inside lib/');
  final base = Directory(p.join(project, 'lib')).resolveSymbolicLinksSync();
  final target = File(p.normalize(p.join(project, file))).resolveSymbolicLinksSync();
  final rel = p.relative(target, from: base);
  if (rel.isEmpty || rel == '.' || rel == '..' || rel.startsWith('../') || p.normalize(p.join(base, rel)) != target) {
    throw const MomentsError('Target escapes lib/');
  }
  return target;
}

final _identifier = RegExp(r'^[A-Za-z][A-Za-z0-9_]*$');

String readDefault(String project, Map<String, Object?> target) {
  final contents = File(sourcePath(project, target['file'])).readAsStringSync();
  switch (target['kind']) {
    case 'arb':
      final value = (jsonDecode(contents) as Map)[target['key']];
      if (value is! String) throw const MomentsError('Mapped ARB label was not found');
      return value;
    case 'dartEnum':
      final symbol = target['symbol'], type = target['type'];
      if (symbol is! String || !_identifier.hasMatch(symbol) || type is! String || !_identifier.hasMatch(type)) {
        throw const MomentsError('Invalid Dart binding');
      }
      final matches = RegExp(
        '^[\\t ]*const $symbol\\s*=\\s*$type\\.([A-Za-z][A-Za-z0-9_]*)\\s*;',
        multiLine: true,
      ).allMatches(contents).toList();
      if (matches.length != 1) throw const MomentsError('Expected one literal Dart enum binding');
      return matches.single[1]!;
  }
  throw const MomentsError('Unsupported source binding');
}
