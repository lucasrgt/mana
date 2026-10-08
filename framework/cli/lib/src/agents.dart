import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'assets.dart';
import 'capabilities.dart';
import 'failure.dart';
import 'features.dart';
import 'manifest.dart';
import 'notebook.dart';
import 'plugins.dart';
import 'primitives.dart';
import 'process.dart';
import 'toolchain.dart';

Map<String, Object?> _agent(Config config, String name) =>
    (table(config, 'agents')[name]! as Map).cast<String, Object?>();

List<String> _strings(Object? value) =>
    (value as List?)?.cast<String>() ?? const [];

void inspectAgents(String root, Config config, List<String> names) {
  for (final name in names) {
    final agent = _agent(config, name);
    final skills = skillPlan(root, _strings(agent['skills']));
    if (name == 'codex') syncCodexSkills(root, skills, check: true);
    if (name == 'claude') pluginPlan(root, _strings(agent['mods']));
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
  if (!runtimeOnly && names.contains('codex')) {
    syncCodexSkills(
      root,
      skillPlan(root, _strings(_agent(config, 'codex')['skills'])),
    );
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

String _toml(Object? value) => switch (value) {
  final String text => jsonEncode(text),
  final List items => '[${items.map(_toml).join(',')}]',
  final Map map =>
    '{${map.entries.map((e) => '${jsonEncode(e.key)}=${_toml(e.value)}').join(',')}}',
  _ => throw ManaFailure('Unsupported TOML value: $value'),
};

Future<int> launch(
  String root,
  Config config,
  String name,
  List<String> forwarded, {
  bool print = false,
}) async {
  if (table(config, 'agents')[name] == null) {
    throw ManaFailure('Agent not configured: $name');
  }
  final agent = _agent(config, name);
  artifactPlan(root, config);
  final skills = skillPlan(root, _strings(agent['skills']));
  final plugins = name == 'claude'
      ? pluginPlan(root, _strings(agent['mods']))
      : <Plugin>[];
  if (name == 'claude' &&
      plugins.any((plugin) => plugin.servers != null) &&
      forwarded.any(
        (v) =>
            v == '--strict-mcp-config' || v.startsWith('--strict-mcp-config='),
      )) {
    throw const ManaFailure(
      '--strict-mcp-config disables plugin MCP; incompatible with the selected mods',
    );
  }
  if (name == 'codex') {
    await locked(root, () async => syncCodexSkills(root, skills));
  }
  final sessions = Directory(projectPath(root, '.mana/sessions'))
    ..createSync(recursive: true);
  final session = sessions.createTempSync('$name-').path;
  final variables = {
    ...Platform.environment,
    'MANA_PROJECT': root,
    'MANA_SESSION': session,
  };
  final env = {
    ...variables,
    for (final MapEntry(:key, :value) in environment(
      agent['env'] ?? const {},
    ).entries)
      key: expand(value, variables),
  };
  final command = agentCommand(root, config, name, variables);
  final mcp = table(config, 'mcp');
  final servers = {
    for (final key in _strings(agent['mcp']))
      key: serverConfig(mcp[key], variables),
  };
  if (name == 'claude') {
    for (final path in copyPlugins(plugins, skills, session, variables)) {
      command.addAll(['--plugin-dir', path]);
    }
    final tools = _strings(agent['tools']),
        disallowed = _strings(agent['disallowed_tools']);
    if (tools.isNotEmpty) command.addAll(['--tools', tools.join(',')]);
    if (disallowed.isNotEmpty) {
      command.addAll(['--disallowedTools', disallowed.join(',')]);
    }
    if (servers.isNotEmpty) {
      final path = p.join(session, 'mcp.json');
      File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'mcpServers': {
            for (final MapEntry(:key, :value) in servers.entries)
              key: serverJson(value),
          },
        }),
      );
      command.addAll(['--mcp-config', path]);
    }
  } else {
    for (final MapEntry(:key, :value) in servers.entries) {
      command.addAll([
        '-c',
        'mcp_servers.mana_$key=${_toml({...serverJson(value), 'cwd': root})}',
      ]);
    }
  }
  final plan = {
    'project': root,
    'agent': name,
    'session': session,
    'command': [...command, ...forwarded],
  };
  if (print) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(plan));
    return 0;
  }
  return (await run(
    plan['command']! as List<String>,
    cwd: root,
    environment: env,
  )).code;
}
