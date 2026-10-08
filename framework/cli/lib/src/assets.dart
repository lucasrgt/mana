import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'failure.dart';
import 'manifest.dart';

String digest(List<int> content) => sha256.convert(content).toString();

typedef PlannedArtifact = ({String file, List<int>? content});

List<PlannedArtifact> artifactPlan(
  String root,
  Config config, {
  bool install = false,
}) => [
  for (final raw in list(table(config, 'setup')['artifacts']))
    () {
      final artifact = (raw! as Map).cast<String, Object?>();
      final path = artifact['path']! as String;
      final file = projectPath(root, path);
      if (File(file).existsSync()) {
        if (digest(File(file).readAsBytesSync()) != artifact['sha256']) {
          throw ManaFailure('Artifact differs from pinned checksum: $path');
        }
        if (FileStat.statSync(file).mode & 0x49 == 0) {
          throw ManaFailure('Artifact is not executable: $path');
        }
        return (file: file, content: null);
      }
      if (!install) {
        throw ManaFailure('Missing artifact: $path; run mana setup');
      }
      final source = expand(artifact['source']! as String, {
        ...Platform.environment,
        'MANA_PROJECT': root,
      });
      final origin = File(
        source.startsWith('/') ? source : projectPath(root, source),
      );
      if (!origin.existsSync()) {
        throw ManaFailure('Missing artifact source: $source');
      }
      final content = origin.readAsBytesSync();
      if (digest(content) != artifact['sha256']) {
        throw ManaFailure('Artifact checksum mismatch: $path');
      }
      return (file: file, content: content);
    }(),
];

void installArtifacts(List<PlannedArtifact> plan) {
  for (final (:file, :content) in plan) {
    if (content == null) continue;
    Directory(p.dirname(file)).createSync(recursive: true);
    final target = File(file);
    if (target.existsSync()) {
      throw ManaFailure('Artifact appeared while installing: $file');
    }
    target.writeAsBytesSync(content, flush: true);
    Process.runSync('chmod', ['700', file]);
  }
}

final _skillName = RegExp(r'^[a-z0-9][a-z0-9-]*$');

Map<String, String> skillPlan(String root, List<String> paths) {
  final result = <String, String>{};
  for (final path in paths) {
    final source = projectPath(root, path);
    if (!Directory(source).existsSync() ||
        !File(projectPath(root, '$path/SKILL.md')).existsSync()) {
      throw ManaFailure('Missing skill: $path');
    }
    final name = path.split('/').last;
    if (!_skillName.hasMatch(name) || result.containsKey(name)) {
      throw ManaFailure('Invalid or duplicate skill: $name');
    }
    result[name] = source;
  }
  return result;
}

void syncCodexSkills(
  String root,
  Map<String, String> skills, {
  bool check = false,
}) {
  final ledger = File(projectPath(root, '.mana/codex-skills.json'));
  final previous = ledger.existsSync()
      ? (jsonDecode(ledger.readAsStringSync()) as Map).cast<String, Object?>()
      : <String, Object?>{};
  final base = projectPath(root, '.agents/skills');
  final desired = {
    for (final MapEntry(:key, :value) in skills.entries)
      key: p.relative(value, from: base),
  };
  for (final MapEntry(:key, :value) in previous.entries) {
    if (!_skillName.hasMatch(key) || value is! String) {
      throw const ManaFailure('Invalid skills ownership ledger');
    }
  }
  final names = {...previous.keys, ...desired.keys};
  for (final name in names) {
    final file = p.join(base, name);
    final type = FileSystemEntity.typeSync(file, followLinks: false);
    if (type == FileSystemEntityType.notFound) continue;
    if (previous[name] == null ||
        type != FileSystemEntityType.link ||
        Link(file).targetSync() != previous[name]) {
      throw ManaFailure('Refusing to overwrite skill: $file');
    }
  }
  if (check) return;
  Directory(base).createSync(recursive: true);
  ledger.parent.createSync(recursive: true);
  for (final name in names) {
    final link = Link(p.join(base, name));
    if (previous[name] != desired[name] && link.existsSync()) link.deleteSync();
    final target = desired[name];
    if (target != null && !link.existsSync()) link.createSync(target);
  }
  final temp = File('${ledger.path}.$pid.tmp');
  try {
    temp.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(desired)}\n',
      flush: true,
    );
    temp.renameSync(ledger.path);
  } finally {
    if (temp.existsSync()) temp.deleteSync();
  }
}

Future<T> locked<T>(String root, Future<T> Function() action) async {
  final lock = File(projectPath(root, '.mana/setup.lock'));
  lock.parent.createSync(recursive: true);
  try {
    lock.createSync(exclusive: true);
    lock.writeAsStringSync('$pid');
  } on FileSystemException {
    throw const ManaFailure(
      'Mana setup is locked; inspect .mana/setup.lock before removing an interrupted lock',
    );
  }
  try {
    return await action();
  } finally {
    if (lock.existsSync()) lock.deleteSync();
  }
}
