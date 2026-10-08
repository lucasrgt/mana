import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:toml/toml.dart';

late String cli;
late String agentBinary;

const _agentSource = r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  if (env['AGENT_MODE'] == 'wait') {
    ProcessSignal.sigterm.watch().listen((_) {
      File('terminated').writeAsStringSync('yes');
      exit(143);
    });
    stdout.writeln('READY');
    await Future<void>.delayed(const Duration(minutes: 1));
    return;
  }
  if (args.contains('--version')) {
    stdout.writeln('fixture 1.0');
    return;
  }
  await Future<void>.delayed(const Duration(milliseconds: 30));
  File('${env['MANA_PROJECT']}/captured.json').writeAsStringSync(jsonEncode({
    'argv': args,
    'cwd': Directory.current.path,
    'session': env['MANA_SESSION'],
    'marker': env['MANA_MARKER'],
  }));
  exitCode = int.parse(env['AGENT_EXIT'] ?? '0');
}
''';

const _taskSource = r'''
import 'dart:io';

Future<void> main(List<String> args) async {
  switch (args.first) {
    case 'write':
      File(args[1]).writeAsStringSync(args[2]);
    case 'exit':
      exit(int.parse(args[1]));
    case 'hang':
      await Future<void>.delayed(const Duration(minutes: 1));
  }
}
''';

late String taskBinary;

/// Compiles the CLI and two fixture programs once per test file.
void compileFixtures() {
  setUpAll(() async {
    final build = Directory.systemTemp.createTempSync('mana-cli-test-');
    final package = Directory.current.path;
    cli = p.join(build.path, 'mana');
    agentBinary = p.join(build.path, 'agent');
    taskBinary = p.join(build.path, 'task');
    File(p.join(build.path, 'agent.dart')).writeAsStringSync(_agentSource);
    File(p.join(build.path, 'task.dart')).writeAsStringSync(_taskSource);
    for (final (source, output) in [
      (p.join(package, 'bin/mana.dart'), cli),
      (p.join(build.path, 'agent.dart'), agentBinary),
      (p.join(build.path, 'task.dart'), taskBinary),
    ]) {
      final result = await Process.run('dart', [
        'compile',
        'exe',
        source,
        '-o',
        output,
      ], workingDirectory: package);
      if (result.exitCode != 0) {
        throw StateError('compile failed: ${result.stderr}');
      }
    }
    _build = build;
  });
  tearDownAll(() => _build?.deleteSync(recursive: true));
}

Directory? _build;

typedef Fixture = ({String root, Map<String, Object?> config});

Fixture fixture() {
  final root = Directory.systemTemp
      .createTempSync('mana project ')
      .resolveSymbolicLinksSync();
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  Directory(p.join(root, 'agents/skills/local')).createSync(recursive: true);
  File(p.join(root, 'agents/skills/local/SKILL.md')).writeAsStringSync(
    '---\nname: local\ndescription: Project fixture\n---\nUse this project only.\n',
  );
  Directory(
    p.join(root, 'agents/mods/claude/local/.claude-plugin'),
  ).createSync(recursive: true);
  File(
    p.join(root, 'agents/mods/claude/local/.claude-plugin/plugin.json'),
  ).writeAsStringSync('{"name":"local"}');
  File(p.join(root, 'agents/mods/claude/local/.mcp.toml')).writeAsStringSync(
    '[search]\ncommand=["${agentBinary}","\${MANA_PROJECT}/agent","\${MANA_SESSION}/state"]\n',
  );
  final agent = {
    'command': [agentBinary],
    'skills': ['agents/skills/local'],
  };
  final config = <String, Object?>{
    'version': 1,
    'agents': {
      'claude': {
        ...agent,
        'mods': ['agents/mods/claude/local'],
        'env': {'MANA_MARKER': root},
      },
      'codex': {
        ...agent,
        'mcp': ['search'],
      },
    },
    'mcp': {
      'search': {
        'command': [
          agentBinary,
          r'${MANA_PROJECT}/agent',
          r'${MANA_SESSION}/state',
        ],
      },
    },
  };
  save(root, config);
  return (root: root, config: config);
}

void save(String root, Map<String, Object?> config) => File(
  p.join(root, 'mana.toml'),
).writeAsStringSync(TomlDocument.fromMap(config).toString());

ProcessResult invoke(
  String cwd,
  List<String> args, [
  Map<String, String> env = const {},
]) {
  final environment = {...Platform.environment, ...env}
    ..remove('MANA_CLAUDE_BIN')
    ..remove('MANA_CODEX_BIN');
  return Process.runSync(
    cli,
    args,
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: false,
  );
}

Map<String, Object?> agents(Map<String, Object?> config, String name) =>
    ((config['agents']! as Map)[name]! as Map).cast<String, Object?>();
