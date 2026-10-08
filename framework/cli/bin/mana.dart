import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;

const _usage = '''
mana setup [--agents claude,codex] [--skip-tasks] | mana setup --runtime-only
mana doctor [--agents claude,codex]
mana agent claude|codex [--print] [-- native arguments]
All commands accept --project directory; otherwise discover nearest mana.toml.

mana contracts install
mana contracts compare --base <json> --candidate <json> [--report <json>] [--json]
mana client generate --input <json> --output <dir> --name <package>
  [--jar <file>] [--consumer <app>] [--report <json>] [--accept-breaking] [--establish-baseline]
mana web version <build/web>
mana mix <mix project> [mix arguments]
mana forms generate --server <mix project> --resource <Module> --output <file.dart>
  [--api-client <package>] [--check]

mana capabilities [topic] [--all] [--json]
  What the framework already does, how to use it and what it replaces.
mana capabilities skill [--check]
  Regenerates (or checks) framework/agents/skills/mana/SKILL.md from the catalog.
mana features list | show <name> | which <path...> | check | changed [--base REV] | coverage [name]  [--json]
mana sense list | learn | --changed [--base REV] | run <sensor...>
  [--budget 5m] [--keep-going] [--dry-run] [--json]
  Picks the cheapest declared sensors (sensors.toml) that cover a change and
  runs them cheapest first; the result is an AVP verdict.
  The shared "feature:<name>" address, declared in features.toml.
mana note add --about <feature:|verb:|moment:|entity:...> --why "..." [--outcome decided|tried|failed|kept]
  [--receipt last|<verdict.json>] [--path <file>]  |  note show <coordinate>  |  note list
  The project's reasoning, addressed by coordinate, with its receipt; stale once the code moved.
mana eval list | run <name> [--agent claude|codex] [--keep]
  Gives an agent a task with no hints in a throwaway worktree (evals/<name>/task.md)
  and checks whether it used the framework as intended (checks.toml) → AVP verdict.
mana intent list | show <id> | approve <id> --by <name> | check <id>
  An ask as situations and criteria (intents/<id>.toml), frozen on approval, checked as an AVP verdict.
mana examples [Module.fun] [--json]
  What each defexample function received and returned in each Moment
  (Mana.Examples), newest first, with what changed since the previous run.
mana mcp --api <url> [--agent <name>] [--flat --contract <openapi.json>] [--stats <file>]
  Serves the app's screens and verbs to an agent over MCP (stdio): open an
  entry, follow a verb a record offers. The token comes from MANA_AGENT_TOKEN.''';

Future<void> _eval(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('agent', defaultsTo: 'claude')
    ..addFlag('keep', negatable: false)
    ..addFlag('json', negatable: false);
  try {
    final values = parser.parse(arguments);
    final json = values.flag('json');
    final root = findProject();
    switch (values.rest) {
      case ['list']:
        final names = AgentEval.list(root);
        _print(names, json: json, text: () => names.join('\n'));
      case ['run', final name]:
        final verdict = await AgentEval.load(root, name).run(
          agent: values.option('agent')!,
          keep: values.flag('keep'),
          progress: json ? null : stdout.writeln,
        );
        _print(
          verdict,
          json: json,
          text: () => [
            for (final r in (verdict['results']! as List).cast<Map>())
              '${r['status']} ${r['criterionId']}${r['reason'] == null ? '' : ': ${r['reason']}'}',
            'AVP verdict: ${verdict['outcome']} · ${verdict['acceptanceScore']} · ${verdict['agent']} in ${verdict['minutes']} min',
          ].join('\n'),
        );
        if (verdict['outcome'] != 'pass') exitCode = 1;
      default:
        throw const ManaFailure(
          'Use mana eval list | run <name> [--agent claude|codex] [--keep]',
        );
    }
  } on FormatException catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  }
}

String? _lastVerdict(String root) {
  final dir = Directory(p.join(root, '.mana/sense'));
  if (!dir.existsSync()) return null;
  final runs = [
    for (final d in dir.listSync().whereType<Directory>())
      if (File(p.join(d.path, 'verdict.json')).existsSync()) d.path,
  ]..sort();
  return runs.isEmpty ? null : p.join(runs.last, 'verdict.json');
}

void _note(List<String> arguments) {
  final parser = ArgParser()
    ..addMultiOption('about')
    ..addOption('why')
    ..addOption('outcome', defaultsTo: 'decided')
    ..addOption('receipt')
    ..addMultiOption('path')
    ..addFlag('json', negatable: false);
  try {
    final values = parser.parse(arguments);
    final json = values.flag('json');
    final root = findProject();
    final notebook = Notebook(root);
    switch (values.rest) {
      case ['add']:
        final receipt = values.option('receipt');
        final note = notebook.add(
          why: values.option('why') ?? '',
          about: values.multiOption('about'),
          outcome: values.option('outcome')!,
          receipt: receipt == 'last' ? _lastVerdict(root) : receipt,
          paths: values.multiOption('path'),
        );
        _print(
          note,
          json: json,
          text: () => 'Anotado ${note['id']}: ${note['why']}',
        );
      case ['show', final coordinate]:
        final notes = notebook.about(coordinate);
        _print(
          notes,
          json: json,
          text: () => notes.isEmpty
              ? 'Nothing noted about $coordinate.'
              : [
                  for (final n in notes)
                    '${n['at']} ${n['outcome']}${n['stale'] == true ? ' (code changed since)' : ''}: ${n['why']}${n['receipt'] is Map ? ' · receipt ${(n['receipt'] as Map)['outcome']}' : ''} [${(n['about'] as List).join(', ')}]',
                ].join('\n'),
        );
      case ['list']:
        final notes = notebook.all();
        _print(
          notes,
          json: json,
          text: () => [
            for (final n in notes) '${n['id']} ${n['outcome']}: ${n['why']}',
          ].join('\n'),
        );
      default:
        throw const ManaFailure(
          'Use mana note add --about <coordinate> --why "..." [--outcome tried|failed|kept] [--receipt last|<verdict.json>] [--path <file>] | show <coordinate> | list',
        );
    }
  } on FormatException catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  }
}

Future<void> _intent(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('by')
    ..addFlag('json', negatable: false);
  try {
    final values = parser.parse(arguments);
    final json = values.flag('json');
    final root = findProject();
    final intents = Intents(root);
    switch (values.rest) {
      case ['list']:
        final all = intents.list();
        _print(
          all,
          json: json,
          text: () => [
            for (final i in all) '${i['id']} (${i['status']}): ${i['ask']}',
          ].join('\n'),
        );
      case ['show', final id]:
        final intent = intents.read(id);
        _print(
          intent,
          json: json,
          text: () => [
            '${intent['id']} (${intent['status']}): ${intent['ask']}',
            for (final s
                in ((intent['situation'] as List?) ?? const []).cast<Map>())
              '  situation ${s['moment']}: ${s['expect']}',
            for (final c in (intent['criterion'] as List).cast<Map>())
              '  criterion ${c['id']}: ${c['moment'] ?? 'sensor ${c['sensor']}'}',
          ].join('\n'),
        );
      case ['approve', final id]:
        final by = values.option('by');
        if (by == null) {
          throw const ManaFailure('Say who approves: --by <name>');
        }
        final intent = intents.approve(id, by: by);
        _print(
          intent,
          json: json,
          text: () => '$id approved by $by; criteria frozen.',
        );
      case ['check', final id]:
        final moments = p.join(frameworkRoot(), 'moments/moments');
        final verdict = await intents.check(
          id,
          progress: json ? null : stdout.writeln,
          moment: (app, name) async => (await Process.run(moments, [
            'suite',
            name,
            '--headless',
            '--project',
            'apps/$app',
          ], workingDirectory: root)).exitCode,
        );
        _print(
          verdict,
          json: json,
          text: () => [
            for (final r in (verdict['results']! as List).cast<Map>())
              '${r['status']} ${r['criterionId']}',
            'AVP verdict: ${verdict['outcome']} · ${verdict['acceptanceScore']}',
          ].join('\n'),
        );
        if (verdict['outcome'] != 'pass') exitCode = 1;
      default:
        throw const ManaFailure(
          'Use mana intent list | show <id> | approve <id> --by <name> | check <id>',
        );
    }
  } on FormatException catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  }
}

void _examples(List<String> arguments) {
  final json = arguments.contains('--json');
  final rest = [
    for (final a in arguments)
      if (a != '--json') a,
  ];
  final value = liveExamples(findProject(), function: rest.firstOrNull);
  final functions = (value['functions']! as Map).cast<String, Object?>();
  if (json) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(value));
    return;
  }
  if (functions.isEmpty) {
    stdout.writeln(
      'No example recorded in ${value['directory']}; mark the function with defexample and run the Moments (moments suite --headless).',
    );
    return;
  }
  for (final MapEntry(:key, value: moments) in functions.entries) {
    stdout.writeln(key);
    for (final m in (moments! as List).cast<Map>()) {
      stdout.writeln(
        '  ${m['moment']} (${m['calls']}x): (${(m['args'] as List).join(', ')}) → ${m['result']}',
      );
      if (m['previous'] != null) {
        stdout.writeln('    changed; before: ${m['previous']}');
      }
    }
  }
}

Future<void> _mcp(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('api')
    ..addOption('agent', defaultsTo: 'agent')
    ..addFlag('flat', negatable: false)
    ..addOption('contract')
    ..addOption('stats');
  final values = parser.parse(arguments);
  final api = values.option('api');
  final token = Platform.environment['MANA_AGENT_TOKEN'];
  if (api == null || token == null || token.isEmpty) {
    stderr.writeln('mana: mcp needs --api <url> and MANA_AGENT_TOKEN');
    exitCode = 1;
    return;
  }
  final List<Map<String, Object?>> tools;
  AgentPost post;
  if (values.flag('flat')) {
    final contract = values.option('contract');
    if (contract == null) {
      stderr.writeln('mana: mcp --flat needs --contract <openapi.json>');
      exitCode = 1;
      return;
    }
    tools = flatTools(jsonDecode(File(contract).readAsStringSync()) as Map);
    post = httpFlatPost(Uri.parse(api), token, tools);
  } else {
    tools = mcpTools;
    post = httpAgentPost(Uri.parse(api), token, agent: values.option('agent')!);
  }
  if (values.option('stats') case final stats?) {
    post = countingPost(post, File(stats));
  }
  await serveMcp(input: stdin, output: stdout, post: post, tools: tools);
}

Future<void> main(List<String> arguments) async {
  switch (arguments.firstOrNull) {
    case 'contracts':
      return _contracts(arguments.skip(1).toList());
    case 'client':
      return _client(arguments.skip(1).toList());
    case 'web':
      return _web(arguments.skip(1).toList());
    case 'mix':
      return _mix(arguments.skip(1).toList());
    case 'lab':
      return _lab(arguments.skip(1).toList());
    case 'new':
      return _new(arguments.skip(1).toList());
    case 'forms':
      return _forms(arguments.skip(1).toList());
    case 'features':
      return _features(arguments.skip(1).toList());
    case 'capabilities':
      return _capabilities(arguments.skip(1).toList());
    case 'sense':
      return _sense(arguments.skip(1).toList());
    case 'mcp':
      return _mcp(arguments.skip(1).toList());
    case 'examples':
      return _examples(arguments.skip(1).toList());
    case 'note':
      return _note(arguments.skip(1).toList());
    case 'eval':
      return _eval(arguments.skip(1).toList());
    case 'intent':
      return _intent(arguments.skip(1).toList());
  }
  try {
    final boundary = arguments.indexOf('--');
    final own = boundary < 0 ? arguments : arguments.sublist(0, boundary);
    final forwarded = boundary < 0
        ? const <String>[]
        : arguments.sublist(boundary + 1);
    final parser = ArgParser()
      ..addOption('project')
      ..addOption('agents')
      ..addFlag('skip-tasks', negatable: false)
      ..addFlag('runtime-only', negatable: false)
      ..addFlag('print', negatable: false)
      ..addFlag('help', negatable: false);
    final ArgResults values;
    try {
      values = parser.parse(own);
    } on FormatException catch (error) {
      throw ManaFailure(error.message);
    }
    if (values.flag('help')) {
      stdout.writeln(_usage);
      return;
    }
    final positionals = values.rest;
    final command = positionals.firstOrNull;
    if (!const ['setup', 'doctor', 'agent'].contains(command) ||
        positionals.length != (command == 'agent' ? 2 : 1)) {
      throw const ManaFailure('Invalid command; use mana --help');
    }
    final agents = values.option('agents');
    if ((values.flag('print') && command != 'agent') ||
        (values.flag('skip-tasks') && command != 'setup') ||
        (agents != null && !const ['setup', 'doctor'].contains(command)) ||
        (forwarded.isNotEmpty && command != 'agent')) {
      throw const ManaFailure('Option not supported for this command');
    }
    final runtimeOnly = values.flag('runtime-only');
    if (runtimeOnly &&
        (command != 'setup' || agents != null || values.flag('skip-tasks'))) {
      throw const ManaFailure(
        '--runtime-only is exclusive to setup without --agents or --skip-tasks',
      );
    }
    final project = values.option('project');
    final root = project != null
        ? Directory(project).resolveSymbolicLinksSync()
        : findProject();
    final config = validate(readManifest(root));
    switch (command) {
      case 'setup':
        await setup(
          root,
          config,
          runtimeOnly ? const [] : selected(config, agents),
          skipTasks: values.flag('skip-tasks'),
          runtimeOnly: runtimeOnly,
        );
      case 'doctor':
        await doctor(root, config, selected(config, agents));
      case 'agent':
        exitCode = await launch(
          root,
          config,
          positionals[1],
          forwarded,
          print: values.flag('print'),
        );
    }
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln('mana: ${error.message}: ${error.path}');
    exitCode = 1;
  } on ProcessException catch (error) {
    stderr.writeln('mana: ${error.message}: ${error.executable}');
    exitCode = 1;
  }
}

Future<void> _contracts(List<String> arguments) async {
  var json = false;
  try {
    final parser = ArgParser()
      ..addOption('base')
      ..addOption('candidate')
      ..addOption('report')
      ..addFlag('json', negatable: false);
    final values = parser.parse(arguments);
    json = values.flag('json');
    switch (values.rest) {
      case ['install']:
        final installed = await installToolchain();
        stdout.writeln('${installed.oasdiff}\n${installed.generator}');
      case ['compare']:
        final base = values.option('base'),
            candidate = values.option('candidate');
        if (base == null || candidate == null) {
          throw const ManaFailure(
            'Use mana contracts compare --base <json> --candidate <json> [--report <json>] [--json]',
          );
        }
        final result = compareContracts(base, candidate);
        if (values.option('report') case final report?) {
          saveReport(report, result);
        }
        stdout.writeln(
          json
              ? const JsonEncoder.withIndent('  ').convert(result)
              : formatComparison(result),
        );
        exitCode = result['exitCode']! as int;
      default:
        throw const ManaFailure('Use mana contracts install|compare');
    }
  } on Object catch (error) {
    final reason = error is ManaFailure ? error.message : '$error';
    stdout.writeln(
      json
          ? jsonEncode({
              'status': 'unavailable',
              'exitCode': 2,
              'reason': reason,
            })
          : reason,
    );
    exitCode = 2;
  }
}

Future<void> _client(List<String> arguments) async {
  try {
    final parser = ArgParser();
    for (final option in [
      'input',
      'output',
      'name',
      'jar',
      'consumer',
      'report',
    ]) {
      parser.addOption(option);
    }
    parser
      ..addFlag('accept-breaking', negatable: false)
      ..addFlag('establish-baseline', negatable: false);
    final values = parser.parse(arguments);
    if (values.rest.length != 1 || values.rest.single != 'generate') {
      throw const ManaFailure(
        'Use mana client generate --input --output --name',
      );
    }
    String required(String key) =>
        values.option(key) ?? (throw ManaFailure('Missing --$key'));
    await generateClient(
      input: required('input'),
      output: required('output'),
      name: required('name'),
      jar: values.option('jar'),
      consumer: values.option('consumer'),
      report: values.option('report'),
      acceptBreaking: values.flag('accept-breaking'),
      establishBaseline: values.flag('establish-baseline'),
    );
  } on Object catch (error) {
    stderr.writeln(error is ManaFailure ? error.message : '$error');
    exitCode = 2;
  }
}

void _web(List<String> arguments) {
  try {
    if (arguments.length != 2 || arguments.first != 'version') {
      throw const ManaFailure('Use mana web version <build/web>');
    }
    versionWebAssets(arguments[1]);
  } on Object catch (error) {
    stderr.writeln('mana: ${error is ManaFailure ? error.message : error}');
    exitCode = 1;
  }
}

Future<void> _mix(List<String> arguments) async {
  try {
    if (arguments.isEmpty) {
      throw const ManaFailure('Use mana mix <mix project> [mix arguments]');
    }
    await mix(
      arguments.first,
      arguments.skip(1).toList(),
      environment: {
        for (final key in ['MIX_ENV'])
          if (Platform.environment[key] case final value?) key: value,
      },
    );
  } on ManaFailure catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

Future<void> _new(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addOption('mana-url')
      ..addOption('mana-ref')
      ..addFlag('setup', defaultsTo: true);
    final values = parser.parse(arguments);
    if (values.rest.length != 1) {
      throw const ManaFailure(
        'Use mana new <folder> [--mana-url <git url>] [--mana-ref <commit>] [--no-setup]',
      );
    }
    await newProject(
      values.rest.single,
      manaUrl: values.option('mana-url'),
      manaRef: values.option('mana-ref'),
      setup: values.flag('setup'),
    );
  } on ManaFailure catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

Future<void> _lab(List<String> arguments) async {
  try {
    final backend = arguments.firstOrNull == '--backend' && arguments.length > 1
        ? arguments[1]
        : null;
    await lab(
      findProject(),
      backend == null ? arguments : arguments.skip(2).toList(),
      backend: backend,
    );
  } on ManaFailure catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  }
}

Future<void> _forms(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addOption('server')
      ..addOption('resource')
      ..addOption('output')
      ..addOption('api-client')
      ..addFlag('check', negatable: false);
    final values = parser.parse(arguments);
    final server = values.option('server'),
        resource = values.option('resource'),
        output = values.option('output');
    if (values.rest.length != 1 ||
        values.rest.single != 'generate' ||
        server == null ||
        resource == null ||
        output == null) {
      throw const ManaFailure(
        'Usage: mana forms generate --server <mix-project> --resource <Module> --output <file.dart> [--check]',
      );
    }
    final result = await generateForms(
      server: server,
      resource: resource,
      output: output,
      check: values.flag('check'),
      apiClient: values.option('api-client'),
    );
    stdout.writeln(jsonEncode(result));
  } on Object catch (error) {
    stderr.writeln(error is ManaFailure ? error.message : '$error');
    exitCode = 1;
  }
}

void _print(
  Object? value, {
  required bool json,
  required String Function() text,
}) => stdout.writeln(
  json ? const JsonEncoder.withIndent('  ').convert(value) : text(),
);

Future<void> _features(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addOption('project')
      ..addOption('base', defaultsTo: 'HEAD')
      ..addFlag('apply', negatable: false)
      ..addFlag('json', negatable: false);
    final values = parser.parse(arguments);
    final json = values.flag('json');
    final rest = values.rest;
    final project = values.option('project');
    final root = project != null
        ? Directory(project).resolveSymbolicLinksSync()
        : findProject();
    final map = FeatureMap.load(root);
    switch (rest) {
      case ['list']:
        _print(
          [
            for (final f in map.features)
              {'name': f.name, 'description': f.description},
          ],
          json: json,
          text: () => [
            for (final f in map.features)
              'feature:${f.name} — ${f.description}',
          ].join('\n'),
        );
      case ['show', final name]:
        final value = map.describe(map.named(name));
        _print(
          value,
          json: json,
          text: () => [
            '${value['address']} — ${value['description']}',
            'Files (${(value['files']! as List).length}):',
            for (final path in (value['files']! as List)) '  $path',
            'Moments (${(value['moments']! as List).length}):',
            for (final moment in (value['moments']! as List)) '  $moment',
          ].join('\n'),
        );
      case ['which', ...final paths] when paths.isNotEmpty:
        final value = {
          for (final path in paths)
            p.normalize(p.relative(p.absolute(path), from: root)): map.owners(
              p.normalize(p.relative(p.absolute(path), from: root)),
            ),
        };
        _print(
          value,
          json: json,
          text: () => [
            for (final MapEntry(:key, :value) in value.entries)
              '$key: ${value.isEmpty ? 'no feature' : value.map((n) => 'feature:$n').join(', ')}',
          ].join('\n'),
        );
      case ['coverage', ...final rest] when rest.length <= 1:
        final sensors = File(p.join(root, Sensors.file)).existsSync()
            ? {for (final s in Sensors.load(root).sensors) s.id: s.covers}
            : const <String, List<String>>{};
        final value = map.coverage(
          [
            for (final file in generatedContracts(root))
              jsonDecode(file.readAsStringSync()),
          ],
          sensorCovers: sensors,
          only: rest.firstOrNull,
        );
        _print(
          value,
          json: json,
          text: () => [
            for (final row in (value['features']! as List).cast<Map>())
              'feature:${row['feature']} · verbs: ${(row['verbs'] as List).length} · moments: ${(row['moments'] as List).length} · sensors: ${(row['sensors'] as List).join(', ')}',
            for (final verb in (value['unexercisedVerbs']! as List))
              '  verb without a moment: $verb',
            for (final feature in (value['featuresWithoutVerbs']! as List))
              '  moments without a verb: feature:$feature',
            for (final verb in (value['verbsWithUnknownFeature']! as List))
              '  unknown feature: $verb',
            for (final verb in (value['verbsWithoutFeature']! as List))
              '  verb without a feature: $verb',
          ].join('\n'),
        );
      case ['remove', final name]:
        final value = map.removal(name, [
          for (final file in generatedContracts(root))
            jsonDecode(file.readAsStringSync()),
        ]);
        if (values.flag('apply')) map.remove(value);
        _print(
          value,
          json: json,
          text: () => [
            '${values.flag('apply') ? 'Removed' : 'Plan to remove'} feature:$name',
            for (final path in (value['delete']! as List))
              '  ${values.flag('apply') ? 'deleted' : 'delete'}: $path',
            for (final row in (value['keep']! as List).cast<Map>())
              '  keep (also owned by ${(row['owners'] as List).map((n) => 'feature:$n').join(', ')}): ${row['path']}',
            for (final moment in (value['moments']! as List))
              '  moment only this feature points to, review: $moment',
            for (final verb in (value['verbs']! as List))
              '  verb still names feature:$name, review: $verb',
            if (!values.flag('apply'))
              'Nothing changed; run again with --apply to delete the files and the features.toml entry.',
          ].join('\n'),
        );
      case ['check']:
        final value = map.check();
        _print(
          value,
          json: json,
          text: () => [
            '${value['status'] == 'passed' ? 'PASSED' : 'FAILED'} · ${value['features']} features · ${value['files']} files under the roots',
            for (final path in (value['unowned']! as List))
              '  no feature: $path',
            for (final glob in (value['stalePaths']! as List))
              '  path without a file: $glob',
            for (final ref in (value['staleMoments']! as List))
              '  unknown moment: $ref',
          ].join('\n'),
        );
        if (value['status'] != 'passed') exitCode = 1;
      case ['changed']:
        final value = map.changed(values.option('base')!);
        _print(
          value,
          json: json,
          text: () => [
            'Features changed since ${value['base']}:',
            for (final f in (value['features']! as List).cast<Map>())
              '  feature:${f['name']} · ${(f['files'] as List).length} files · moments: ${(f['moments'] as List).isEmpty ? 'none' : (f['moments'] as List).join(', ')}',
            for (final path in (value['unowned']! as List))
              '  no feature: $path',
          ].join('\n'),
        );
      default:
        throw const ManaFailure(
          'Use mana features list|show <name>|which <path...>|check|changed [--base REV]|coverage [name]|remove <name> [--apply]',
        );
    }
  } on FormatException catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 2;
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 2;
  }
}

Future<void> _capabilities(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addFlag('all', negatable: false)
      ..addFlag('check', negatable: false)
      ..addFlag('json', negatable: false);
    final values = parser.parse(arguments);
    final framework = frameworkRoot();
    final catalog = Catalog.load(framework);
    if (values.rest case ['skill']) {
      final file = File(p.join(framework, 'agents/skills/mana/SKILL.md'));
      final skill = catalog.skill();
      if (values.flag('check')) {
        if (!file.existsSync() || file.readAsStringSync() != skill) {
          stderr.writeln(
            'mana: ${file.path} is out of date; run mana capabilities skill',
          );
          exitCode = 1;
        }
        return;
      }
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(skill);
      stdout.writeln(file.path);
      return;
    }
    final found = catalog.search(
      values.rest.join(' '),
      all: values.flag('all'),
    );
    _print(
      [for (final c in found) Catalog.json(c)],
      json: values.flag('json'),
      text: () => found.isEmpty
          ? 'Nothing in the catalog matches; mana capabilities --all lists everything, planned included.'
          : found.map(Catalog.text).join('\n\n'),
    );
  } on FormatException catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 2;
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 2;
  }
}

Future<void> _sense(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addOption('project')
      ..addOption('base', defaultsTo: 'HEAD')
      ..addOption('budget')
      ..addFlag('changed', negatable: false)
      ..addFlag('keep-going', negatable: false)
      ..addFlag('dry-run', negatable: false)
      ..addFlag('json', negatable: false);
    final values = parser.parse(arguments);
    final json = values.flag('json');
    final project = values.option('project');
    final root = project != null
        ? Directory(project).resolveSymbolicLinksSync()
        : findProject();
    final sensors = Sensors.load(root);
    final List<(Sensor, String)> plan;
    var changed = const <String>[];
    switch (values.rest) {
      case ['list']:
        _print(
          [
            for (final s in sensors.sensors)
              {
                'id': s.id,
                'proves': s.proves,
                'cost': formatCost(s.cost),
                'covers': s.covers,
                'requires': s.requires,
                'gate': s.gate,
              },
          ],
          json: json,
          text: () => [
            for (final s in sensors.sensors)
              '${s.id.padRight(28)} ${formatCost(s.cost).padLeft(4)}  ${s.proves.padRight(10)} ${s.requires.isEmpty ? '' : 'requires ${s.requires.join(', ')}'}',
          ].join('\n'),
        );
        return;
      case ['learn']:
        final lock = Sensors.learn(root);
        _print(
          lock,
          json: json,
          text: () => [
            'sensors.lock: measured on ${(lock['sensors']! as Map).length} sensors',
            for (final MapEntry(:key, :value)
                in (lock['sensors']! as Map).cast<String, Map>().entries)
              '${key.padRight(28)} ${value['runs']}x · median ${value['medianMs']}ms · p95 ${value['p95Ms']}ms · failure ${value['failRate']} · flaky ${value['flakyRate']} · ${value['catchesPerMinute']} catches/min',
          ].join('\n'),
        );
        return;
      case [] when values.flag('changed'):
        changed = sensors.changedSince(values.option('base')!);
        final paths = changed;
        plan = sensors.selectFor(paths, features: FeatureMap.tryLoad(root));
        if (plan.isEmpty) {
          _print(
            {
              'outcome': 'inconclusive',
              'reason': 'No declared sensor covers the change',
              'changed': paths,
            },
            json: json,
            text: () =>
                'No declared sensor covers the change (${paths.length} files).',
          );
          exitCode = 2;
          return;
        }
      case ['run', ...final ids] when ids.isNotEmpty:
        plan = [for (final id in ids) (sensors.named(id), 'requested')];
      default:
        throw const ManaFailure(
          'Use mana sense list | learn | --changed [--base REV] | run <sensor...>',
        );
    }
    if (values.flag('dry-run')) {
      _print(
        [
          for (final (s, reason) in plan)
            {
              'id': s.id,
              'cost': formatCost(s.cost),
              'proves': s.proves,
              'reason': reason,
            },
        ],
        json: json,
        text: () => [
          for (final (s, reason) in plan)
            '${s.id} (${formatCost(s.cost)}, ${s.proves}): $reason',
        ].join('\n'),
      );
      return;
    }
    final verdict = await sensors.run(
      plan,
      paths: changed,
      budget: values.option('budget') == null
          ? null
          : parseCost(values.option('budget')!),
      keepGoing: values.flag('keep-going'),
      progress: json ? null : stdout.writeln,
    );
    _print(
      verdict,
      json: json,
      text: () => [
        'AVP verdict: ${verdict['outcome']}',
        for (final r in (verdict['results']! as List).cast<Map>())
          if (r['status'] != 'pass')
            '  ${r['status']}: ${r['criterionId']} · ${r['reason']}',
      ].join('\n'),
    );
    exitCode = switch (verdict['outcome']) {
      'pass' => 0,
      'fail' => 1,
      _ => 2,
    };
  } on FormatException catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 2;
  } on ManaFailure catch (error) {
    stderr.writeln('mana: ${error.message}');
    exitCode = 2;
  }
}
