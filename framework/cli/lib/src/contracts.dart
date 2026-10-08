import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'failure.dart';
import 'toolchain.dart';

typedef Contract = ({
  Map<String, Object?> value,
  List<int> bytes,
  String sha256,
});

Contract readContract(String file) {
  final bytes = File(file).readAsBytesSync();
  if (bytes.length > 16 * 1024 * 1024) {
    throw const ManaFailure('Contract exceeds 16 MiB');
  }
  final value = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
  if (!RegExp(r'^3\.0\.\d+$').hasMatch('${value['openapi'] ?? ''}') ||
      value['paths'] == null ||
      value['info'] == null) {
    throw const ManaFailure(
      'Expected a self-contained OpenAPI 3.0 JSON contract',
    );
  }
  void walk(Object? node) {
    switch (node) {
      case final Map map:
        final ref = map[r'$ref'];
        if (ref is String && !ref.startsWith('#/')) {
          throw const ManaFailure(
            'External contract references are unsupported; export a self-contained contract',
          );
        }
        map.values.forEach(walk);
      case final List items:
        items.forEach(walk);
    }
  }

  walk(value);
  return (value: value, bytes: bytes, sha256: sha256Hex(bytes));
}

Map<String, Object?> compareContracts(String base, String candidate) {
  final started = Stopwatch()..start();
  final before = readContract(base), after = readContract(candidate);
  final binary = oasdiffBinary();
  final temporary = Directory(cacheDirectory(['contracts', 'tmp']))
    ..createSync(recursive: true);
  final directory = temporary.createTempSync('compare-');
  final ProcessResult result;
  try {
    final baseFile = File(p.join(directory.path, 'base.json'))
      ..writeAsBytesSync(before.bytes);
    final candidateFile = File(p.join(directory.path, 'candidate.json'))
      ..writeAsBytesSync(after.bytes);
    result = Process.runSync(
      binary,
      [
        'breaking',
        baseFile.path,
        candidateFile.path,
        '--format',
        'json',
        '--fail-on',
        'WARN',
        '--allow-external-refs=false',
      ],
      environment: {
        'PATH': Platform.environment['PATH'] ?? '',
        'LANG': 'C.UTF-8',
      },
      includeParentEnvironment: false,
    );
  } finally {
    directory.deleteSync(recursive: true);
  }
  if (result.exitCode != 0 && result.exitCode != 1) {
    throw const ManaFailure(
      'Contract comparison unavailable; check that both exports are valid OpenAPI',
    );
  }
  final List<Map<String, Object?>> changes;
  try {
    changes = (jsonDecode(result.stdout as String) as List)
        .map((c) => (c as Map).cast<String, Object?>())
        .toList();
  } on FormatException {
    throw const ManaFailure('Invalid contract comparison output');
  }
  if (changes.any(
    (c) =>
        c['id'] == null ||
        c['text'] is! String ||
        ![1, 2, 3].contains(c['level']),
  )) {
    throw const ManaFailure('Invalid contract comparison findings');
  }
  int level(Map<String, Object?> change) => change['level']! as int;
  if ((result.exitCode == 1) != changes.any((c) => level(c) >= 2)) {
    throw const ManaFailure('Inconsistent contract comparison result');
  }
  final status = changes.any((c) => level(c) == 3)
      ? 'breaking'
      : changes.any((c) => level(c) == 2)
      ? 'review'
      : 'compatible';
  final oasdiff = (pinnedToolchain()['oasdiff']! as Map)
      .cast<String, Object?>();
  return {
    'version': 1,
    'status': status,
    'exitCode': status == 'compatible' ? 0 : 1,
    'direction': 'existing client against candidate server declaration',
    'baseSha256': before.sha256,
    'candidateSha256': after.sha256,
    'tool': {'name': 'oasdiff', 'version': oasdiff['version']},
    'changes': [
      for (final c in changes)
        {
          for (final key in [
            'id',
            'text',
            'level',
            'operation',
            'operationId',
            'path',
            'fingerprint',
          ])
            if (c[key] != null) key: c[key],
        },
    ],
    'durationMs': started.elapsedMicroseconds / 1000,
    'scope':
        'Declared HTTP compatibility; not Dart source compatibility, authorization behavior, or a running server attestation',
  };
}

void saveReport(String file, Map<String, Object?> value) {
  final target = File(p.absolute(file));
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

String formatComparison(Map<String, Object?> report) {
  final changes = (report['changes']! as List).cast<Map>();
  return [
    'Contrato: ${report['status']} · ${changes.length} achado(s) · ${(report['durationMs']! as num).round()} ms',
    for (final c in changes)
      '${c['operation'] ?? ''} ${c['path'] ?? ''} · ${c['id']}: ${c['text']}',
    'Scope: declared HTTP contract. Compile the consumer and run the affected Moments.',
  ].join('\n');
}
