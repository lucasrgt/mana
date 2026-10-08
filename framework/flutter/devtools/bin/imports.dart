import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';

// Parse directives with Dart's analyzer. No app code is executed. All conditional
// branches are included: a plan must not silently depend on the host platform.
Future<void> main() async {
  try {
    final input = jsonDecode(await stdin.transform(utf8.decoder).join()) as Map;
    final sources = (input['files'] as List).cast<Map>();
    if (input['version'] != 1 || sources.length > 20000) {
      throw const FormatException('Invalid source inventory');
    }
    final files = <String, List<String>>{};
    for (final item in sources) {
      final path = item['path'] as String;
      final source = item['content'] as String;
      final parsed = parseString(
        content: source,
        path: path,
        throwIfDiagnostics: false,
      );
      if (parsed.errors.isNotEmpty) {
        throw const FormatException('Dart source contains parse diagnostics');
      }
      final imports = <String>{};
      for (final directive in parsed.unit.directives) {
        if (directive is UriBasedDirective) {
          final uri = directive.uri.stringValue;
          if (uri == null)
            throw const FormatException('Nonliteral directive URI');
          imports.add(uri);
        }
        if (directive is NamespaceDirective) {
          for (final config in directive.configurations) {
            final uri = config.uri.stringValue;
            if (uri == null)
              throw const FormatException('Nonliteral conditional URI');
            imports.add(uri);
          }
        }
        if (directive is PartOfDirective && directive.uri != null) {
          final uri = directive.uri!.stringValue;
          if (uri == null) throw const FormatException('Nonliteral part URI');
          imports.add(uri);
        }
      }
      files[path] = imports.toList()..sort();
    }
    stdout.writeln(jsonEncode({'version': 1, 'files': files}));
  } catch (_) {
    // Diagnostic source text could contain app secrets; return only a category.
    stderr.writeln(
      'Dart import graph unavailable: invalid input, source or syntax',
    );
    exitCode = 2;
  }
}
