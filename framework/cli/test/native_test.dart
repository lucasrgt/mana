import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

typedef Call = ({String name, Map<String, Object?> input});

/// A local Anthropic Messages endpoint that answers with the given tool calls,
/// then with FIXTURE_OK, recording every request.
Future<
  ({
    List<Map<String, Object?>> requests,
    String url,
    Future<void> Function() close,
  })
>
provider(List<Call> calls) async {
  final requests = <Map<String, Object?>>[];
  var index = 0;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final raw = await utf8.decoder.bind(request).join();
    final body = (jsonDecode(raw.isEmpty ? '{}' : raw) as Map)
        .cast<String, Object?>();
    final response = request.response;
    if (!request.uri.path.contains('/messages')) return response.close();
    if (request.uri.path.contains('count_tokens')) {
      response.write('{"input_tokens":1}');
      return response.close();
    }
    requests.add(body);
    final call = index < calls.length ? calls[index] : null;
    index++;
    final block = call != null
        ? {
            'type': 'tool_use',
            'id': 'tool_$index',
            'name': call.name,
            'input': call.input,
          }
        : {'type': 'text', 'text': 'FIXTURE_OK'};
    final message = {
      'id': 'msg_fixture',
      'type': 'message',
      'role': 'assistant',
      'model': 'claude-sonnet-4-6',
      'content': [block],
      'stop_reason': call != null ? 'tool_use' : 'end_turn',
      'stop_sequence': null,
      'usage': {'input_tokens': 1, 'output_tokens': 1},
    };
    if (body['stream'] != true) {
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(message));
      return response.close();
    }
    final events = [
      {
        'type': 'message_start',
        'message': {...message, 'content': <Object>[], 'stop_reason': null},
      },
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': call != null
            ? {...block, 'input': <String, Object>{}}
            : {...block, 'text': ''},
      },
      {
        'type': 'content_block_delta',
        'index': 0,
        'delta': call != null
            ? {
                'type': 'input_json_delta',
                'partial_json': jsonEncode(call.input),
              }
            : {'type': 'text_delta', 'text': 'FIXTURE_OK'},
      },
      {'type': 'content_block_stop', 'index': 0},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': message['stop_reason'], 'stop_sequence': null},
        'usage': {'output_tokens': 1},
      },
      {'type': 'message_stop'},
    ];
    response.headers.contentType = ContentType('text', 'event-stream');
    response.write(
      events
          .map(
            (event) =>
                'event: ${event['type']}\ndata: ${jsonEncode(event)}\n\n',
          )
          .join(),
    );
    await response.close();
  });
  return (
    requests: requests,
    url: 'http://127.0.0.1:${server.port}',
    close: () => server.close(),
  );
}

void main() {
  compileFixtures();
  final claude = Platform.environment['MANA_TEST_CLAUDE'],
      fff = Platform.environment['MANA_TEST_FFF'];
  final codex = Platform.environment['MANA_TEST_CODEX'];
  final project = Platform.environment['MANA_TEST_PROJECT'] ?? '';

  test(
    'native Claude loads FFF slices and Pi tools through Mana with a local provider',
    skip: claude == null || fff == null || project.isEmpty || !Directory(project).existsSync()
        ? 'needs MANA_TEST_CLAUDE, MANA_TEST_FFF and MANA_TEST_PROJECT (a project with agents/)'
        : false,
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final (:root, config: _) = fixture();
      final config = readManifest(project)..remove('setup');
      (config['agents']! as Map).remove('codex');
      await Process.run('cp', ['-R', p.join(project, 'agents'), root]);
      ((config['agents']! as Map)['claude'] as Map)['command'] = [claude];
      final mcp = File(p.join(root, 'agents/mods/claude/fff-search/.mcp.toml'));
      mcp.writeAsStringSync(
        mcp.readAsStringSync().replaceAll(
          r'${MANA_PROJECT}/.mana/bin/fff-mcp',
          fff!,
        ),
      );
      save(root, config);
      File(
        p.join(root, 'actor.py'),
      ).writeAsStringSync('def ActorRegistry():\n    return "actors"\n');
      expect(
        (await run(['git', 'init', '-q'], cwd: root, capture: true)).code,
        0,
      );
      const prefix = 'mcp__plugin_fff-search_fff__';
      final api = await provider([
        (
          name: '${prefix}grep',
          input: {
            'query': 'ActorRegistry',
            'slice': {'depth': 1},
          },
        ),
        (name: 'mcp__pi-efficiency__read', input: {'path': 'actor.py'}),
      ]);
      addTearDown(api.close);
      final env = {
        'PATH': Platform.environment['PATH']!,
        'HOME': Platform.environment['HOME']!,
        'MANA_CLAUDE_BIN': claude!,
        'ANTHROPIC_API_KEY': 'sk-ant-local-fixture',
        'ANTHROPIC_BASE_URL': api.url,
        'CLAUDE_CONFIG_DIR': p.join(root, '.native-config'),
        'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1',
        'DISABLE_AUTOUPDATER': '1',
        'DISABLE_TELEMETRY': '1',
      };
      final result = await run(
        [
          cli,
          'agent',
          'claude',
          '--',
          '--setting-sources',
          'project',
          '--permission-mode',
          'dontAsk',
          '--no-session-persistence',
          '--model',
          'claude-sonnet-4-6',
          '--effort',
          'low',
          '--allowedTools',
          '$prefix*,mcp__pi-efficiency__read,Read',
          '-p',
          '--output-format',
          'json',
          '--',
          'Run the fixture.',
        ],
        cwd: root,
        environment: env,
        capture: true,
        timeout: const Duration(seconds: 45),
      );
      expect(result.code, 0, reason: result.output);
      expect(result.output, contains('FIXTURE_OK'));
      final results = [
        for (final message in api.requests.last['messages']! as List)
          if ((message as Map)['content'] is List)
            for (final block in message['content'] as List)
              if ((block as Map)['type'] == 'tool_result') block,
      ];
      expect(results, hasLength(2));
      expect(
        results.every((r) => r['is_error'] != true),
        isTrue,
        reason: jsonEncode(results),
      );
      expect(
        results.every(
          (r) => jsonEncode(r['content']).contains('ActorRegistry'),
        ),
        isTrue,
      );
      final prompt = jsonEncode(api.requests.first['system']);
      expect(prompt, contains('Use FFF for indexed repository searches'));
      expect(prompt, contains('mcp__pi-efficiency__read'));
      final tools = (api.requests.first['tools']! as List).cast<Map>();
      final names = tools.map((tool) => tool['name']).toList();
      expect(names, containsAll(['${prefix}grep', 'mcp__pi-efficiency__read']));
      expect(names, isNot(contains('Grep')));
      expect(names, isNot(contains('Glob')));
      final grep = tools.firstWhere((tool) => tool['name'] == '${prefix}grep');
      expect(
        ((grep['input_schema'] as Map)['properties'] as Map)['slice'],
        isNotNull,
      );
    },
  );

  test(
    'native Codex discovers project skill links and accepts scoped MCP overrides',
    skip: codex == null ? 'needs MANA_TEST_CODEX' : false,
    timeout: const Timeout(Duration(seconds: 30)),
    () async {
      final (:root, :config) = fixture();
      agents(config, 'codex')['command'] = [codex!];
      save(root, config);
      final planned = invoke(root, [
        'agent',
        'codex',
        '--print',
        '--',
        'app-server',
      ]);
      expect(planned.exitCode, 0, reason: '${planned.stderr}');
      final command =
          ((jsonDecode(planned.stdout as String) as Map)['command'] as List)
              .cast<String>();
      final home = Directory(p.join(root, '.codex-test'))..createSync();
      final child = await Process.start(
        command.first,
        command.skip(1).toList(),
        workingDirectory: root,
        environment: {'CODEX_HOME': home.path},
      );
      addTearDown(() => child.kill());
      final errors = StringBuffer();
      child.stderr.transform(utf8.decoder).listen(errors.write);
      final pending = <int, Completer<Object?>>{};
      child.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final message = jsonDecode(line) as Map;
            final waiting = pending.remove(message['id']);
            if (waiting == null) return;
            message['error'] != null
                ? waiting.completeError(jsonEncode(message['error']))
                : waiting.complete(message['result']);
          });
      var id = 0;
      Future<Object?> request(String method, Object params) {
        final current = ++id, done = Completer<Object?>();
        pending[current] = done;
        child.stdin.writeln(
          jsonEncode({'id': current, 'method': method, 'params': params}),
        );
        return done.future.timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw StateError('RPC timeout: $method; $errors'),
        );
      }

      await request('initialize', {
        'clientInfo': {'name': 'mana-test', 'version': '0.1.0'},
        'capabilities': {'experimentalApi': true},
      });
      child.stdin.writeln('{"method":"initialized"}');
      final skills = await request('skills/list', {
        'cwds': [root],
        'forceReload': true,
      });
      expect(jsonEncode(skills), contains('Project fixture'));
      final loaded = await request('config/read', {
        'cwd': root,
        'includeLayers': false,
      });
      expect(jsonEncode(loaded), contains('mana_search'));
    },
  );
}
