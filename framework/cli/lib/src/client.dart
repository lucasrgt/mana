import 'dart:convert';
import 'dart:io';

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
    // An operation answering a free-form object imports json_object a second time.
    final imported = RegExp(r"^import '[^']+';\n", multiLine: true);
    // dart-dio declares a top-level array response as BuiltList but reads it as
    // a BuiltSet, so the cast fails at runtime; read it as the list it declares.
    final listed = <String>{};
    for (final file in Directory(
      p.join(stage, 'lib/src/api'),
    ).listSync().whereType<File>()) {
      final seen = <String>{};
      file.writeAsStringSync(
        file
            .readAsStringSync()
            .replaceAllMapped(
              imported,
              (match) => seen.add(match[0]!) ? match[0]! : '',
            )
            .replaceAllMapped(
              RegExp(
                r'FullType\(BuiltSet, \[FullType\((\w+)\)\]\),(\s*\) as BuiltList<)',
              ),
              (match) {
                listed.add(match[1]!);
                return 'FullType(BuiltList, [FullType(${match[1]})]),${match[2]}';
              },
            ),
      );
    }
    final serializersFile = File(p.join(stage, 'lib/src/serializers.dart'));
    var serializers = serializersFile.readAsStringSync();
    for (final type in listed) {
      if (!serializers.contains('FullType(BuiltList, [FullType($type)])')) {
        serializers = serializers.replaceFirst(
          RegExp(r'\n    \)\.build\(\);'),
          '\n      ..addBuilderFactory(\n        const FullType(BuiltList, [FullType($type)]),\n        () => ListBuilder<$type>(),\n      )\n    ).build();',
        );
      }
    }
    serializersFile.writeAsStringSync(serializers);
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
