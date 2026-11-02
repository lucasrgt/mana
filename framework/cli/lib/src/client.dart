import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import 'contracts.dart';
import 'failure.dart';
import 'primitives.dart';
import 'toolchain.dart';

const _pretty = JsonEncoder.withIndent('  ');

/// Generates the dart-dio client for [input] into [output] through a staging
/// directory: the existing package is replaced only after its contract was
/// compared, the serializers built and the package (and [consumer]) analyzed.
Future<Map<String, Object?>> generateClient({
  required String input,
  required String output,
  required String name,
  String? jar,
  String? consumer,
  String? report,
  bool acceptBreaking = false,
  bool establishBaseline = false,
}) async {
  if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
    throw const ManaFailure('Invalid Dart package name');
  }
  output = p.absolute(output);
  input = p.absolute(input);
  final generatorFile = p.absolute(jar ?? generatorJar());
  final generator = (pinnedToolchain()['generator']! as Map)
      .cast<String, Object?>();
  final owned = Directory(output).existsSync();
  if (owned &&
      !File(p.join(output, '.openapi-generator/VERSION')).existsSync()) {
    throw const ManaFailure('Refusing to replace a hand-owned package');
  }
  if (sha256Hex(File(generatorFile).readAsBytesSync()) != generator['sha256']) {
    throw const ManaFailure(
      'OpenAPI Generator checksum differs from the pinned toolchain',
    );
  }
  final contract = readContract(input);
  final metadataFile = File(p.join(output, '.mana/client.json')),
      baseline = p.join(output, '.mana/contract.json');
  final reportFile = p.absolute(
    report ?? p.join(p.dirname(output), '.proofs', 'contracts', '$name.json'),
  );
  Map<String, Object?> comparison;
  if (owned && metadataFile.existsSync()) {
    final metadata = (jsonDecode(metadataFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
    if (metadata['version'] != 1 ||
        metadata['package'] != name ||
        metadata['contractSha256'] != readContract(baseline).sha256) {
      throw const ManaFailure(
        'Generated client baseline is inconsistent; inspect its provenance before regeneration',
      );
    }
    comparison = compareContracts(baseline, input);
    saveReport(reportFile, comparison);
    stdout.writeln(formatComparison(comparison));
    if (comparison['status'] != 'compatible' && !acceptBreaking) {
      throw ManaFailure(
        'Existing client would need migration. Review $reportFile; use --accept-breaking only for an intentional migration.',
      );
    }
  } else {
    if (owned && !establishBaseline) {
      throw const ManaFailure(
        'Existing client has no recorded contract; regenerate once with --establish-baseline after reviewing its source contract',
      );
    }
    comparison = {
      'version': 1,
      'status': owned ? 'baseline-establishment' : 'initial',
      'candidateSha256': contract.sha256,
      'scope':
          'No previous generated-client baseline; no backward compatibility claim',
    };
    saveReport(reportFile, comparison);
  }
  // The comparator and generator must consume the same candidate bytes.
  if (comparison['candidateSha256'] != contract.sha256) {
    throw const ManaFailure(
      'Contract changed during comparison; generate again',
    );
  }
  Directory(p.dirname(output)).createSync(recursive: true);
  final stage = Directory(
    p.dirname(output),
  ).createTempSync('.generated-client-').path;
  final backup = '$stage-previous';
  final stageInput = File(p.join(stage, '.mana/contract.json'));
  stageInput.parent.createSync();
  stageInput.writeAsBytesSync(contract.bytes);
  final temporary = Directory(p.join(stage, '.build-tmp'))..createSync();
  Future<void> run(String command, List<String> args, {String? cwd}) async {
    final child = await Process.start(
      command,
      args,
      workingDirectory: cwd ?? stage,
      environment: {'TMPDIR': temporary.path},
      mode: ProcessStartMode.inheritStdio,
    );
    final code = await child.exitCode;
    if (code != 0) throw ManaFailure('$command failed ($code)');
  }

  var failureStage = 'generation';
  try {
    await run('java', [
      '-jar',
      generatorFile,
      'validate',
      '-i',
      stageInput.path,
    ]);
    await run('java', [
      '-jar',
      generatorFile,
      'generate',
      '-g',
      'dart-dio',
      '-i',
      stageInput.path,
      '-o',
      stage,
      '--additional-properties',
      'pubName=$name,pubVersion=0.1.0,pubPublishTo=none,hideGenerationTimestamp=true',
      '--global-property',
      'apiTests=false,modelTests=false,apiDocs=false,modelDocs=false',
      // Each operation keeps its own request/response model names; reusing a
      // structurally identical one (e.g. a phone code for an email code) misleads readers.
      '--inline-schema-options', 'SKIP_SCHEMA_REUSE=true',
    ]);
    patchGeneratedClient(stage);
    writePrimitives(
      stage,
      name,
      output,
      jsonDecode(utf8.decode(contract.bytes)),
    );
    final lock = File(p.join(output, 'pubspec.lock'));
    if (lock.existsSync()) lock.copySync(p.join(stage, 'pubspec.lock'));
    final ignore = File(p.join(stage, '.gitignore'));
    ignore.writeAsStringSync(
      '${ignore.readAsStringSync()}\n# Keep private code generation reproducible.\n!pubspec.lock\n',
    );
    failureStage = 'serializers';
    await run('dart', ['pub', 'get']);
    await run('dart', ['run', 'build_runner', 'build']);
    await run('dart', [
      'fix',
      '--apply',
      '--code=unused_import',
      '--code=unused_element_parameter',
    ]);
    failureStage = 'package-analysis';
    await run('dart', ['analyze', 'lib']);
    File(p.join(stage, '.mana/client.json')).writeAsStringSync(
      '${_pretty.convert({
        'version': 1,
        'package': name,
        'contractSha256': contract.sha256,
        'generator': {
          for (final key in ['name', 'version', 'sha256']) key: generator[key],
        },
      })}\n',
    );
    Directory(p.join(stage, '.dart_tool')).deleteSync(recursive: true);
    // Consumer analysis uses the app's existing resolution at the stable package path.
    if (owned) Directory(output).renameSync(backup);
    try {
      Directory(stage).renameSync(output);
      if (consumer != null) {
        failureStage = 'consumer-analysis';
        final analysis = await Process.start(
          'dart',
          ['analyze', 'lib'],
          workingDirectory: p.absolute(consumer),
          mode: ProcessStartMode.inheritStdio,
        );
        if (await analysis.exitCode != 0) {
          throw const ManaFailure(
            'Dart consumer analysis failed; previous client restored',
          );
        }
      }
    } catch (_) {
      if (Directory(output).existsSync()) {
        Directory(output).deleteSync(recursive: true);
      }
      if (Directory(backup).existsSync()) Directory(backup).renameSync(output);
      rethrow;
    }
    final leftover = Directory(p.join(output, '.build-tmp'));
    if (leftover.existsSync()) leftover.deleteSync(recursive: true);
    if (Directory(backup).existsSync()) {
      Directory(backup).deleteSync(recursive: true);
    }
    final result = {
      ...comparison,
      if (comparison['status'] == 'baseline-establishment')
        'status': 'baseline-established',
      'generated': true,
      'consumerAnalyzed': consumer != null,
    };
    saveReport(reportFile, result);
    stdout.writeln(
      'Generated and analyzed $name${consumer != null ? ' and its Dart consumer' : ''}',
    );
    return result;
  } catch (_) {
    saveReport(reportFile, {
      ...comparison,
      'generated': false,
      'failureStage': failureStage,
    });
    rethrow;
  } finally {
    if (Directory(stage).existsSync()) {
      Directory(stage).deleteSync(recursive: true);
    }
  }
}

/// Fixes dart-dio's output in [stage] where it is wrong for Mana's contracts,
/// on the parsed source (`package:analyzer`), each edit replacing only the
/// characters it changes. The api files are read in name order, so the list
/// builders' order does not depend on the directory listing.
void patchGeneratedClient(String stage) {
  final listed = <String>{};
  final apis =
      Directory(
          p.join(stage, 'lib/src/api'),
        ).listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in apis) {
    final read = readListsAsLists(
      withoutRepeatedImports(file.readAsStringSync()),
    );
    listed.addAll(read.types);
    file.writeAsStringSync(read.source);
  }
  final serializers = File(p.join(stage, 'lib/src/serializers.dart'));
  serializers.writeAsStringSync(
    withListBuilders(serializers.readAsStringSync(), listed),
  );
}

/// [source] without an import repeated word for word: an operation answering
/// a free-form object imports `json_object` a second time.
String withoutRepeatedImports(String source) {
  final seen = <String>{};
  final edits = <_Edit>[];
  for (final directive in _parse(source).directives) {
    final text = source.substring(directive.offset, directive.end);
    if (directive is! ImportDirective ||
        seen.add(text) ||
        !_startsLine(source, directive.offset) ||
        !source.startsWith('\n', directive.end)) {
      continue;
    }
    edits.add((offset: directive.offset, end: directive.end + 1, text: ''));
  }
  return _apply(source, edits);
}

/// dart-dio declares a top-level array response as `BuiltList<T>` but reads
/// it with `FullType(BuiltSet, [FullType(T)])`, so the cast fails at runtime:
/// each such read asks for the list it declares. [types] are the `T`s, which
/// the serializers then need a list builder for ([withListBuilders]).
({String source, Set<String> types}) readListsAsLists(String source) {
  final reads = _SetReadsAsList();
  _parse(source).accept(reads);
  return (
    source: _apply(source, [
      for (final container in reads.containers)
        (offset: container.offset, end: container.end, text: 'BuiltList'),
    ]),
    types: reads.types,
  );
}

/// [serializers] with a `ListBuilder<T>` factory for each of [types] it
/// lacks, appended in order to the cascade `serializers` builds.
String withListBuilders(String serializers, Iterable<String> types) {
  final unit = _parse(serializers);
  final cascade = _serializersCascade(unit);
  final missing = [
    for (final type in types)
      if (cascade == null || !_buildsList(cascade, type)) type,
  ];
  if (missing.isEmpty) return serializers;
  if (cascade == null) {
    throw const ManaFailure(
      'Generated serializers.dart has no serializers cascade to register list builders in',
    );
  }
  return _apply(serializers, [
    (
      offset: cascade.end,
      end: cascade.end,
      text: [
        for (final type in missing)
          '\n      ..addBuilderFactory(\n        const FullType(BuiltList, [FullType($type)]),\n        () => ListBuilder<$type>(),\n      )',
      ].join(),
    ),
  ]);
}

typedef _Edit = ({int offset, int end, String text});

CompilationUnit _parse(String source) => parseString(content: source).unit;

bool _startsLine(String source, int offset) =>
    offset == 0 || source[offset - 1] == '\n';

String _apply(String source, List<_Edit> edits) {
  final buffer = StringBuffer();
  var at = 0;
  for (final edit in edits..sort((a, b) => a.offset.compareTo(b.offset))) {
    buffer
      ..write(source.substring(at, edit.offset))
      ..write(edit.text);
    at = edit.end;
  }
  return (buffer..write(source.substring(at))).toString();
}

/// `FullType(Container, [FullType(Element)])`, const or not, as its parts.
({SimpleIdentifier container, String element})? _fullTypeOf(Argument e) {
  final arguments = _fullTypeArguments(e);
  if (arguments case [
    SimpleIdentifier container,
    ListLiteral(elements: [final Expression inner]),
  ]) {
    if (_fullTypeArguments(inner) case [SimpleIdentifier element]) {
      return (container: container, element: element.name);
    }
  }
  return null;
}

List<Argument>? _fullTypeArguments(Argument e) => switch (e) {
  InstanceCreationExpression(
    constructorName: ConstructorName(
      type: NamedType(importPrefix: null, typeArguments: null),
      name: null,
    ),
  )
      when e.constructorName.type.name.lexeme == 'FullType' =>
    e.argumentList.arguments,
  MethodInvocation(target: null, typeArguments: null)
      when e.methodName.name == 'FullType' =>
    e.argumentList.arguments,
  _ => null,
};

final class _SetReadsAsList extends RecursiveAstVisitor<void> {
  final containers = <SimpleIdentifier>[];
  final types = <String>{};

  @override
  void visitAsExpression(AsExpression node) {
    final declared = node.type;
    final read = node.expression;
    if (declared is NamedType &&
        declared.name.lexeme == 'BuiltList' &&
        declared.question == null &&
        read is MethodInvocation &&
        read.methodName.name == 'deserialize') {
      final element = switch (declared.typeArguments?.arguments) {
        [NamedType(typeArguments: null, question: null) && final type] =>
          type.name.lexeme,
        _ => null,
      };
      for (final argument
          in read.argumentList.arguments.whereType<NamedArgument>()) {
        if (argument.name.lexeme != 'specifiedType') continue;
        final type = _fullTypeOf(argument.argumentExpression);
        if (type != null &&
            type.container.name == 'BuiltSet' &&
            type.element == element) {
          containers.add(type.container);
          types.add(element!);
        }
      }
    }
    super.visitAsExpression(node);
  }
}

/// The cascade in `serializers = (_$serializers.toBuilder()..…).build()`.
CascadeExpression? _serializersCascade(CompilationUnit unit) {
  for (final declaration
      in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
    for (final variable in declaration.variables.variables) {
      if (variable.name.lexeme != 'serializers') continue;
      if (variable.initializer case MethodInvocation(
        methodName: SimpleIdentifier(name: 'build'),
        target: ParenthesizedExpression(
          expression: final CascadeExpression cascade,
        ),
      )) {
        return cascade;
      }
    }
  }
  return null;
}

bool _buildsList(CascadeExpression cascade, String type) =>
    cascade.cascadeSections.any((section) {
      if (section case MethodInvocation(
        methodName: SimpleIdentifier(name: 'addBuilderFactory'),
        argumentList: ArgumentList(arguments: [final first, ...]),
      )) {
        final built = _fullTypeOf(first);
        return built?.container.name == 'BuiltList' && built?.element == type;
      }
      return false;
    });
