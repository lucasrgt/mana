import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'contracts.dart';
import 'elixir.dart';
import 'failure.dart';
import 'toolchain.dart';

Object? canonical(Object? value) => switch (value) {
  final List items => items.map(canonical).toList(),
  final Map map => {
    for (final key in map.keys.cast<String>().toList()..sort())
      key: canonical(map[key]),
  },
  _ => value,
};

String _digest(List<int> bytes) => sha256Hex(bytes);
String _digestText(String text) => sha256Hex(utf8.encode(text));

String treeDigest(String directory) {
  final files = <List<String>>[];
  void visit(String path) {
    final entries = Directory(path).listSync(followLinks: false)
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final entry in entries) {
      final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        visit(entry.path);
      } else if (type == FileSystemEntityType.file) {
        files.add([
          p.relative(entry.path, from: directory),
          _digest(File(entry.path).readAsBytesSync()),
        ]);
      } else {
        throw const ManaFailure(
          'Unexpected linked file in compiler or client source',
        );
      }
    }
  }

  visit(directory);
  return _digestText(jsonEncode(files));
}

// Copy and gesture-key strings are escaped literals. They do not change the
// SDK call or Dart types. Everything that affects generated types is retained.
Map<String, Object?> _typingContract(Map<String, Object?> contract) => {
  ...contract,
  'forms': [
    for (final form
        in (contract['forms']! as List).cast<Map<String, Object?>>())
      {
        for (final MapEntry(:key, :value) in form.entries)
          if (!const ['submit', 'submit_key', 'failure'].contains(key))
            key: key == 'inputs'
                ? [
                    for (final input
                        in (value! as List).cast<Map<String, Object?>>())
                      {
                        for (final entry in input.entries)
                          if (!const [
                            'label',
                            'key',
                            'invalid',
                          ].contains(entry.key))
                            entry.key: entry.value,
                      },
                  ]
                : value,
      },
  ],
};

Future<String> _run(String command, List<String> args, {String? cwd}) async {
  final result = await Process.run(command, args, workingDirectory: cwd);
  if (result.exitCode != 0) {
    throw ManaFailure(
      '$command ${args.first} failed:\n${result.stdout}${result.stderr}',
    );
  }
  return result.stdout as String;
}

String? _read(String path) =>
    File(path).existsSync() ? File(path).readAsStringSync() : null;

/// Compiles the presentation forms of an Ash [resource] into one managed Dart
/// file and its `.mana.json` provenance, publishing only when they change.
Future<Map<String, Object?>> generateForms({
  required String server,
  required String resource,
  required String output,
  bool check = false,
  String? apiClient,
}) async {
  if (!RegExp(
    r'^([A-Z][A-Za-z0-9_]*\.)*[A-Z][A-Za-z0-9_]*$',
  ).hasMatch(resource)) {
    throw const ManaFailure('Expected server, Elixir resource and Dart output');
  }
  final root = workspaceRoot();
  server = p.absolute(server);
  output = p.absolute(output);
  if (!output.endsWith('.dart')) {
    throw const ManaFailure('Output must end in .dart');
  }
  for (final path in [server, output]) {
    if (p.relative(path, from: root).startsWith('..')) {
      throw const ManaFailure(
        'Presentation consumer must be inside the vendored workspace',
      );
    }
  }
  final metadata = '$output.mana.json', lock = File('$output.lock');
  Directory(p.dirname(output)).createSync(recursive: true);
  try {
    lock.createSync(exclusive: true);
  } on FileSystemException {
    throw const ManaFailure(
      'Form publication locked; inspect the generating process before recovering its lock',
    );
  }
  final stagingRoot = Directory(p.join(frameworkRoot(), 'ash/.toolchain'))
    ..createSync(recursive: true);
  final staging = stagingRoot.createTempSync('forms-');
  try {
    final priorMetadata = _read(metadata), priorSource = _read(output);
    final prior = priorMetadata == null
        ? null
        : (jsonDecode(priorMetadata) as Map).cast<String, Object?>();
    if (priorSource != null &&
        (prior == null ||
            prior['outputSha256'] != _digest(File(output).readAsBytesSync()))) {
      throw const ManaFailure(
        'Generated form was edited or is unmanaged; move custom code into a Dart field builder before regenerating',
      );
    }
    var apiOptions = <String>[];
    Map<String, Object?>? clientProvenance;
    Contract? clientBaseline;
    if (apiClient != null) {
      apiClient = p.absolute(apiClient);
      if (p.relative(apiClient, from: root).startsWith('..')) {
        throw const ManaFailure('API client must be in the vendored workspace');
      }
      clientBaseline = readContract(p.join(apiClient, '.mana/contract.json'));
      clientProvenance =
          (jsonDecode(
                    File(
                      p.join(apiClient, '.mana/client.json'),
                    ).readAsStringSync(),
                  )
                  as Map)
              .cast();
      final generator = (pinnedToolchain()['generator']! as Map)
          .cast<String, Object?>();
      final recorded = (clientProvenance['generator'] as Map?) ?? const {};
      if (clientProvenance['version'] != 1 ||
          !RegExp(
            r'^[a-z][a-z0-9_]*$',
          ).hasMatch('${clientProvenance['package'] ?? ''}') ||
          clientProvenance['contractSha256'] != clientBaseline.sha256 ||
          recorded['name'] != generator['name'] ||
          recorded['version'] != generator['version'] ||
          recorded['sha256'] != generator['sha256']) {
        throw const ManaFailure(
          'API client provenance is inconsistent with the pinned generator',
        );
      }
      final input = File(p.join(staging.path, 'api.json'))
        ..writeAsBytesSync(clientBaseline.bytes);
      apiOptions = [
        '--api-spec',
        p.relative(input.path, from: server),
        '--api-package',
        clientProvenance['package']! as String,
      ];
    }
    final compilation = p.join(staging.path, 'compiled.json');
    await mix(server, [
      'mana.forms',
      resource,
      p.relative(compilation, from: server),
      ...apiOptions,
    ]);
    final compiled = (jsonDecode(File(compilation).readAsStringSync()) as Map)
        .cast<String, Object?>();
    final contract = (compiled['contract']! as Map).cast<String, Object?>();
    final forms = (contract['forms']! as List).cast<Map<String, Object?>>();
    final dart = File(p.join(staging.path, 'form.dart'))
      ..writeAsStringSync(compiled['dart']! as String);
    await _run('dart', ['format', dart.path]);
    final source = dart.readAsStringSync();
    Map<String, Object?>? analysisReceipt;
    if (forms.any((form) => form['binding'] != null)) {
      var consumer = p.dirname(output);
      while (!File(p.join(consumer, 'pubspec.yaml')).existsSync()) {
        final parent = p.dirname(consumer);
        if (parent == consumer ||
            p.relative(parent, from: root).startsWith('..')) {
          throw const ManaFailure(
            'Generated bindings need a Flutter consumer with resolved dependencies',
          );
        }
        consumer = parent;
      }
      final packageFile = File(
        p.join(consumer, '.dart_tool/package_config.json'),
      );
      final packages =
          ((jsonDecode(packageFile.readAsStringSync()) as Map)['packages']
                  as List)
              .cast<Map>();
      final entries = packages
          .where((entry) => entry['name'] == clientProvenance!['package'])
          .toList();
      if (entries.length != 1 ||
          entries.single['packageUri'] != 'lib/' ||
          Directory(
                p.fromUri(
                  packageFile.uri.resolve(entries.single['rootUri'] as String),
                ),
              ).resolveSymbolicLinksSync() !=
              Directory(apiClient!).resolveSymbolicLinksSync()) {
        throw const ManaFailure(
          'Consumer resolves a different API package than the recorded client',
        );
      }
      final sdkSource = treeDigest(p.join(apiClient, 'lib'));
      final sdkVersion = await _run('dart', ['--version']);
      final fingerprint = _digestText(
        jsonEncode(
          canonical({
            'contract': _typingContract(contract),
            'client': clientProvenance,
            'sdkSource': sdkSource,
            'sdkVersion': sdkVersion,
            'packages': _digest(packageFile.readAsBytesSync()),
            'producer': treeDigest(
              p.join(frameworkRoot(), 'ash/presentation/lib'),
            ),
            'publisher': _digest(
              File(
                p.join(frameworkRoot(), 'cli/lib/src/forms.dart'),
              ).readAsBytesSync(),
            ),
          }),
        ),
      );
      if ((prior?['analysis'] as Map?)?['fingerprint'] == fingerprint) {
        analysisReceipt = (prior!['analysis']! as Map).cast();
      } else {
        final proofRoot = Directory(p.join(consumer, '.dart_tool'))
          ..createSync(recursive: true);
        final analysis = proofRoot.createTempSync('mana-forms-');
        try {
          final candidate = File(p.join(analysis.path, 'candidate.dart'))
            ..writeAsStringSync(source);
          await _run('dart', [
            'analyze',
            '--fatal-infos',
            candidate.path,
          ], cwd: consumer);
          analysisReceipt = {
            'fingerprint': fingerprint,
            'sourceSha256': _digestText(source),
            'analyzer': 'dart analyze --fatal-infos',
          };
        } finally {
          analysis.deleteSync(recursive: true);
        }
      }
      if (treeDigest(p.join(apiClient, 'lib')) != sdkSource) {
        throw const ManaFailure(
          'API client source changed during form generation',
        );
      }
      if (readContract(p.join(apiClient, '.mana/contract.json')).sha256 !=
          clientBaseline!.sha256) {
        throw const ManaFailure('API contract changed during form generation');
      }
    }
    final meta =
        '${const JsonEncoder.withIndent('  ').convert(canonical({'version': 1, 'contract': contract, 'client': clientProvenance, 'analysis': analysisReceipt, 'outputSha256': _digestText(source)}))}\n';
    final unchanged = _read(output) == source && _read(metadata) == meta;
    if (check && !unchanged) {
      throw const ManaFailure(
        'Generated form is stale; run generate-forms without --check',
      );
    }
    if (!check && !unchanged) {
      // Publish only managed files. Consumer builders/adapters are never rewritten.
      if (_read(output) != priorSource || _read(metadata) != priorMetadata) {
        throw const ManaFailure(
          'Form files changed during compilation; inspect and regenerate',
        );
      }
      if (priorSource != source) {
        final temp = File('$output.tmp')..createSync(exclusive: true);
        temp
          ..writeAsStringSync(source)
          ..renameSync(output);
      }
      final temp = File('$metadata.tmp')..createSync(exclusive: true);
      temp
        ..writeAsStringSync(meta)
        ..renameSync(metadata);
    }
    return {
      'status': unchanged ? 'current' : 'generated',
      'forms': forms.length,
      'output': output,
      'sha256': _digestText(source),
    };
  } finally {
    staging.deleteSync(recursive: true);
    lock.deleteSync();
  }
}
