import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:toml/toml.dart';

import 'support.dart';

Map<String, Object?> _json(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast();

void main() {
  compileFixtures();

  test(
    'two concurrent projects have separate plugins, MCP state, cwd and arguments',
    () async {
      final fixtures = [fixture(), fixture()];
      final environment = {...Platform.environment}
        ..remove('MANA_CLAUDE_BIN')
        ..remove('MANA_CODEX_BIN');
      final results = await Future.wait([
        for (final (:root, config: _) in fixtures)
          run(
            [cli, 'agent', 'claude', '--', '-p', r'keep spaces; $(literal)'],
            cwd: root,
            environment: environment,
            capture: true,
            timeout: const Duration(seconds: 10),
          ),
      ]);
      expect(
        results.every((result) => result.code == 0),
        isTrue,
        reason: '$results',
      );
      final captures = [
        for (final (:root, config: _) in fixtures)
          _json(p.join(root, 'captured.json')),
      ];
      expect(captures[0]['session'], isNot(captures[1]['session']));
      for (var index = 0; index < 2; index++) {
        final capture = captures[index],
            root = fixtures[index].root,
            other = fixtures[1 - index].root;
        expect(capture['cwd'], root);
        expect(capture['marker'], root);
        final args = (capture['argv']! as List).cast<String>();
        expect(args.sublist(args.length - 2), [
          '-p',
          r'keep spaces; $(literal)',
        ]);
        expect(jsonEncode(capture).contains(other), isFalse);
        final plugin = args[args.indexOf('--plugin-dir') + 1];
        final mcp = _json(p.join(plugin, '.mcp.json'));
        final search = (mcp['search']! as Map)['args']! as List;
        expect(search[1], p.join(capture['session']! as String, 'state'));
        expect(search[0], p.join(root, 'agent'));
        expect(args.any((value) => value.contains('bypass')), isFalse);
      }
    },
  );

  test(
    'Codex overrides are valid TOML and skill lookup remains local to the project',
    () {
      final (:root, config: _) = fixture();
      final result = invoke(root, [
        'agent',
        'codex',
        '--print',
        '--',
        'exec',
        'test prompt',
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final plan = (jsonDecode(result.stdout as String) as Map)
          .cast<String, Object?>();
      final command = (plan['command']! as List).cast<String>();
      final override = command[command.indexOf('-c') + 1];
      final server =
          ((TomlDocument.parse(override).toMap()['mcp_servers']
                  as Map)['mana_search']
              as Map);
      expect(server['cwd'], root);
      expect(
        (server['args'] as List)[1],
        p.join(plan['session']! as String, 'state'),
      );
      expect(command.sublist(command.length - 2), ['exec', 'test prompt']);
      expect(
        File(p.join(root, '.agents/skills/local/SKILL.md')).readAsStringSync(),
        contains('Project fixture'),
      );
    },
  );

  test(
    'nested invocation discovers the nearest project and propagates child exit',
    () {
      final (:root, config: _) = fixture();
      final nested = Directory(p.join(root, 'src/deep'))
        ..createSync(recursive: true);
      final result = invoke(
        nested.path,
        ['agent', 'claude'],
        {'AGENT_EXIT': '9'},
      );
      expect(result.exitCode, 9, reason: '${result.stderr}');
      expect(_json(p.join(root, 'captured.json'))['cwd'], root);
    },
  );

  test(
    'selected Claude plugin MCP cannot silently disappear through strict config',
    () {
      final (:root, config: _) = fixture();
      expect(
        invoke(root, ['agent', 'claude', '--', '--strict-mcp-config']).stderr,
        contains('incompatible'),
      );
      expect(
        invoke(root, ['agent', 'unknown']).stderr,
        contains('not configured'),
      );
      expect(
        invoke(root, ['doctor', '--skip-tasks']).stderr,
        contains('Option not supported'),
      );
    },
  );

  test(
    'changing project source affects the next session, not the previous snapshot',
    () {
      final (:root, config: _) = fixture();
      final file = File(p.join(root, 'agents/mods/claude/local/content.txt'))
        ..writeAsStringSync('v1');
      final first =
          jsonDecode(
                invoke(root, ['agent', 'claude', '--print']).stdout as String,
              )
              as Map;
      file.writeAsStringSync('v2');
      final second =
          jsonDecode(
                invoke(root, ['agent', 'claude', '--print']).stdout as String,
              )
              as Map;
      expect(
        File(
          p.join(first['session'] as String, 'plugins/local/content.txt'),
        ).readAsStringSync(),
        'v1',
      );
      expect(
        File(
          p.join(second['session'] as String, 'plugins/local/content.txt'),
        ).readAsStringSync(),
        'v2',
      );
    },
  );

  test(
    'dependency timeout interrupts the command and prevents later tasks',
    () {
      final (:root, :config) = fixture();
      config['setup'] = {
        'tasks': [
          {
            'name': 'timeout',
            'timeout_seconds': 1,
            'command': [taskBinary, 'hang'],
          },
          {
            'name': 'later',
            'command': [taskBinary, 'write', 'later', 'yes'],
          },
        ],
      };
      save(root, config);
      final result = invoke(root, ['setup']);
      expect(result.stderr, contains('timeout (exit 124)'));
      expect(File(p.join(root, 'later')).existsSync(), isFalse);
      expect(File(p.join(root, '.mana/setup.lock')).existsSync(), isFalse);
    },
  );

  test('launcher forwards termination and reports child status', () async {
    final (:root, config: _) = fixture();
    final environment = {...Platform.environment, 'AGENT_MODE': 'wait'}
      ..remove('MANA_CLAUDE_BIN');
    final child = await Process.start(
      cli,
      ['agent', 'claude'],
      workingDirectory: root,
      environment: environment,
    );
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    final ready = Completer<void>();
    child.stdout.transform(utf8.decoder).listen((chunk) {
      if (chunk.contains('READY') && !ready.isCompleted) ready.complete();
    });
    child.stderr.drain<void>();
    await ready.future.timeout(const Duration(seconds: 5));
    child.kill(ProcessSignal.sigterm);
    expect(await child.exitCode, 143);
    expect(File(p.join(root, 'terminated')).readAsStringSync(), 'yes');
  });
}
