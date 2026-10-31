import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'assets.dart';
import 'capabilities.dart';
import 'failure.dart';
import 'features.dart';
import 'manifest.dart';
import 'notebook.dart';
import 'primitives.dart';
import 'process.dart';
import 'toolchain.dart';

Map<String, Object?> _agent(Config config, String name) =>
    (table(config, 'agents')[name]! as Map).cast<String, Object?>();

List<String> _strings(Object? value) =>
    (value as List?)?.cast<String>() ?? const [];

/// Codex reads this much of AGENTS.md by default (`project_doc_max_bytes`).
const codexDocLimit = 32 * 1024;

/// The framework the project builds on, as a path from its root: this
/// checkout when it lies inside the project, else the `mana/` submodule.
String projectFramework(String root) {
  String? running;
  try {
    running = frameworkRoot();
  } on ManaFailure {
    running = null;
  }
  if (running != null && p.isWithin(root, running)) {
    return p.relative(running, from: root);
  }
  if (File(p.join(root, 'mana/framework/catalog.toml')).existsSync()) {
    return 'mana/framework';
  }
  throw const ManaFailure(
    'No Mana framework inside the project (expected mana/framework)',
  );
}

/// Keeps the catalog's core in AGENTS.md (between the mana:core markers; the
/// rest of the file is the project's) and, for Claude, CLAUDE.md importing
/// it, so every Claude and Codex session starts with the loop and the
/// capabilities before any code. [check] reports drift instead of writing.
void syncGuidance(String root, List<String> names, {bool check = false}) {
  if (names.isEmpty) return;
  final framework = projectFramework(root);
  final block = Catalog.load(p.join(root, framework)).core(framework);
  final agents = File(projectPath(root, 'AGENTS.md'));
  final text = agents.existsSync() ? agents.readAsStringSync() : '';
  final begin = text.indexOf(Catalog.coreBegin);
  final end = text.indexOf(Catalog.coreEnd);
  if ((begin < 0) != (end < 0) || end < begin) {
    throw const ManaFailure(
      'AGENTS.md has a broken mana:core block; remove what is left of it and run mana setup',
    );
  }
  final updated = begin >= 0
      ? text.replaceRange(begin, end + Catalog.coreEnd.length, block)
      : text.trim().isEmpty
      ? '$block\n'
      : '${text.trimRight()}\n\n$block\n';
  final size = utf8.encode(updated).length;
  if (size > codexDocLimit) {
    throw ManaFailure(
      'AGENTS.md would be ${(size / 1024).toStringAsFixed(1)} KiB; Codex reads only the first '
      '${codexDocLimit ~/ 1024} KiB. Move project detail into docs/ or a skill',
    );
  }
  final claude = File(projectPath(root, 'CLAUDE.md'));
  final instructions = claude.existsSync() ? claude.readAsStringSync() : null;
  final imports =
      instructions != null &&
      RegExp(r'^@AGENTS\.md\s*$', multiLine: true).hasMatch(instructions);
  final importMissing = names.contains('claude') && !imports;
  if (check) {
    if (updated != text) {
      throw const ManaFailure(
        'The Mana block in AGENTS.md is missing or out of date with the catalog; run mana setup --skip-tasks',
      );
    }
    if (importMissing) {
      throw const ManaFailure(
        'CLAUDE.md does not import AGENTS.md, so Claude never reads the Mana block; run mana setup --skip-tasks',
      );
    }
    return;
  }
  if (updated != text) agents.writeAsStringSync(updated);
  if (importMissing) {
    claude.writeAsStringSync(
      instructions == null ? '@AGENTS.md\n' : '@AGENTS.md\n\n$instructions',
    );
  }
}

void inspectAgents(String root, Config config, List<String> names) {
  for (final name in names) {
    final agent = _agent(config, name);
    syncSkills(
      root,
      name,
      skillPlan(root, _strings(agent['skills'])),
      check: true,
    );
  }
  for (final task in list(table(config, 'setup')['tasks'])) {
    projectPath(root, (task! as Map)['cwd'] ?? '.', allowRoot: true);
  }
}

Future<void> setup(
  String root,
  Config config,
  List<String> names, {
  bool skipTasks = false,
  bool runtimeOnly = false,
}) => locked(root, () async {
  final tasks = list(
    table(config, 'setup')['tasks'],
  ).map((t) => (t! as Map).cast<String, Object?>());
  if (runtimeOnly) {
    for (final task in tasks) {
      projectPath(root, task['cwd'] ?? '.', allowRoot: true);
    }
  } else {
    inspectAgents(root, config, names);
    installArtifacts(artifactPlan(root, config, install: true));
  }
  if (!skipTasks) {
    for (final task in tasks) {
      stderr.writeln('mana setup: ${task['name']}');
      final variables = {...Platform.environment, 'MANA_PROJECT': root};
      final command = [
        for (final value in argv(task['command'], 'task.command'))
          expand(value, variables),
      ];
      final result = await run(
        command,
        cwd: projectPath(root, task['cwd'] ?? '.', allowRoot: true),
        timeout: Duration(seconds: task['timeout_seconds'] as int? ?? 600),
      );
      if (result.code != 0) {
        throw ManaFailure(
          'Setup task failed: ${task['name']} (exit ${result.code})',
        );
      }
    }
  }
  if (!runtimeOnly) {
    syncGuidance(root, names);
    for (final name in names) {
      syncSkills(
        root,
        name,
        skillPlan(root, _strings(_agent(config, name)['skills'])),
      );
    }
  }
  stdout.writeln(
    runtimeOnly
        ? 'Mana runtime dependency tasks completed; agents and their artifacts were not configured.'
        : 'Mana setup ready: ${names.join(', ')}${skipTasks ? ' (dependency tasks skipped)' : ''}',
  );
});

Future<void> doctor(String root, Config config, List<String> names) async {
  for (final product in productPaths(root, config)) {
    stdout.writeln(
      '${product.name}: ${[?product.backend, ...product.frontend].join(' + ')}',
    );
  }
  inspectAgents(root, config, names);
  artifactPlan(root, config);
  syncGuidance(root, names, check: true);
  String? framework;
  try {
    framework = frameworkRoot();
  } on ManaFailure {
    framework = null;
  }
  if (framework != null &&
      File(p.join(framework, 'catalog.toml')).existsSync()) {
    final catalog = Catalog.load(framework);
    final skill = File(p.join(framework, 'agents/skills/mana/SKILL.md'));
    if (!skill.existsSync() || skill.readAsStringSync() != catalog.skill()) {
      throw const ManaFailure(
        'The Mana skill is out of date with catalog.toml; run mana capabilities skill',
      );
    }
    stdout.writeln(
      'catalog: ${catalog.capabilities.where((c) => c.status == 'available').length} capabilities in the agent skill',
    );
    final ids = {for (final c in catalog.capabilities) c.id};
    for (final contract in generatedContracts(root)) {
      final gaps = primitiveGaps(jsonDecode(contract.readAsStringSync()), ids);
      if (gaps.isNotEmpty) {
        throw ManaFailure(
          'Primitives in ${p.relative(contract.path, from: root)} are not whole: ${gaps.join('; ')}',
        );
      }
      final orphans = unexplainedRules(
        jsonDecode(contract.readAsStringSync()),
        Notebook(root),
      );
      if (orphans.isNotEmpty) {
        throw ManaFailure(
          'Rules point to notes the notebook does not have: ${orphans.join('; ')}',
        );
      }
    }
  }
  if (FeatureMap.tryLoad(root) case final features?) {
    final report = features.check();
    if (report['status'] != 'passed') {
      throw ManaFailure(
        'features.toml is out of date; run mana features check '
        '(${(report['unowned']! as List).length} unowned files, '
        '${(report['stalePaths']! as List).length + (report['staleMoments']! as List).length} stale references)',
      );
    }
    stdout.writeln(
      'features: ${report['features']} features own ${report['files']} files',
    );
  }
  for (final name in names) {
    final command = agentCommand(root, config, name);
    final result = await run(
      [...command, '--version'],
      cwd: root,
      capture: true,
      timeout: const Duration(seconds: 15),
    );
    if (result.code != 0) {
      throw ManaFailure('Agent unavailable: $name (exit ${result.code})');
    }
    stdout.writeln('$name: ${result.output.trim()}');
  }
  stdout.writeln(
    'Mana configuration and artifacts verified; no model request made.',
  );
}
