import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'adapter.dart';
import 'affected.dart';
import 'check.dart';
import 'down.dart';
import 'errors.dart';
import 'flutter_target.dart';
import 'format.dart';
import 'graph.dart';
import 'inspect_compact.dart';
import 'instance_state.dart';
import 'journey.dart';
import 'impact.dart' show buildImportsTool;
import 'manifest.dart';
import 'protocol.dart';
import 'reset.dart';
import 'sandbox.dart';
import 'suite.dart';

const help = '''Moments — edit, resume and verify Flutter

  moments capabilities --json      Protocol and capabilities declared by the engine
  moments graph --json             Declared parent map, without running the app
  moments refresh --check          Refreshes, resumes and verifies the active Moment
  moments refresh --restart --check Restarts to apply main/initState/initializers
  moments profile <name>           Runs the same journey with a latency/actions/queries profile
  moments recover                  Releases an interrupted journey after inspecting its effects
  moments list                    Lists declared situations
  moments open <name>              Switches the running instance to a saved situation
  moments open <name> --fresh      Recreates this Moment's initial UI situation
  moments down                    Stops or recovers the instance, keeping data
  moments reset --discard-data     Removes the stopped isolated database and its resume states
  moments status                  Shows the refresh in progress
  moments status --local          Inspects resources and preparation, even without an active bridge
  moments inspect                 State, files and criteria of the active Moment
  moments inspect --full --json    Full inspection, including catalog and editing
  moments up <name>               Starts the local instance (keeps running)
  moments up <name> --fresh       Prepares data and UI state again, explicitly
  moments up <name> --device linux  Opens the native Linux app with the same journey
  moments up <name> --device android:<serial>  Uses an explicit Android device over ADB
  moments up <name> --retry-preparation  Resumes an interrupted idempotent service preparation
  moments up <name> --backend-only  Only Postgres + backend + bridge, without the dev Flutter
  moments suite [name...] [--workers N] [--debug-build]  Runs Moments in parallel (compiled profile artifact, isolated context per Moment)
  moments suite [name...] --headless  Same suite on the widget runtime (flutter_tester), without a browser
  moments suite --affected [--base REV]  Only the Moments affected since REV (default HEAD)
  moments sync                    Exports the Ash DSL
  moments affected [--base HEAD]   Plans the affected Moments; runs no actions
  moments tools                   Compiles the Dart import parser used by affected

Options: --json for structured output; --project <dir> to choose the app.
In open, --fresh replaces the saved UI state of the chosen Moment only. In up,
a prepared instance resumes by default; --fresh runs the preparation again.
Profile also runs preparation and gestures, including declared writes; it does not repeat the journey.
A partial profile exits with 2 even when the criteria passed; do not infer zero queries
from missing events. CPU/heap and load are not measured by this command.
The preparation recipe may change its isolated data; refresh does not rerun recipes or gestures.
Without --project, uses the current app or the nearest .moments.json in parent directories.
Exits: 0 success, 1 failure, 2 unavailable/invalid usage. Refresh without --check
only starts the refresh. Up/sync stream logs and do not accept --json.
''';

const _commands = {
  'suite',
  'profile',
  'capabilities',
  'graph',
  'reset',
  'down',
  'refresh',
  'recover',
  'list',
  'open',
  'status',
  'inspect',
  'up',
  'sync',
  'affected',
};

final _momentName = RegExp(r'^[a-z][a-z0-9-]*$');

/// Parsed command line. Absent flags stay null so validation mirrors which
/// options the user actually wrote.
final class CliOptions {
  bool json = false, help = false, check = false;
  bool restart = false, full = false, local = false, discardData = false, retryPreparation = false;
  bool fresh = false, backendOnly = false, debugBuild = false, headless = false;
  bool affected = false, wasm = false;
  int? workers;
  String? base, device, project;
  String? command, name;
  List<String> names = const [];
}

Never _usage(String message) => throw MomentsError(message);

CliOptions parseArgs(List<String> args) {
  final result = CliOptions();
  final words = <String>[];
  String? next(int i) => i + 1 < args.length ? args[i + 1] : null;
  bool missing(int i) => next(i) == null || next(i)!.startsWith('-');
  for (var i = 0; i < args.length; i++) {
    final value = args[i];
    switch (value) {
      case '--json':
        result.json = true;
      case '--help' || '-h':
        result.help = true;
      case '--check':
        result.check = true;
      case '--restart':
        result.restart = true;
      case '--full':
        result.full = true;
      case '--local':
        result.local = true;
      case '--discard-data':
        result.discardData = true;
      case '--retry-preparation':
        result.retryPreparation = true;
      case '--fresh':
        result.fresh = true;
      case '--backend-only':
        result.backendOnly = true;
      case '--debug-build':
        result.debugBuild = true;
      case '--headless':
        result.headless = true;
      case '--affected':
        result.affected = true;
      case '--wasm':
        result.wasm = true;
      case '--workers':
        if (!RegExp(r'^[1-8]$').hasMatch(next(i) ?? '') || result.workers != null) {
          _usage('--workers needs a single number from 1 to 8.');
        }
        result.workers = int.parse(args[++i]);
      case '--base':
        if (missing(i) || result.base != null) _usage('--base needs a single Git revision.');
        result.base = args[++i];
      case '--device':
        if (missing(i)) _usage('--device needs a device.');
        result.device = flutterTarget(args[++i]).device;
      case '--project':
        if (missing(i)) _usage('--project needs a directory.');
        result.project = args[++i];
      default:
        if (value.startsWith('-')) _usage('Unknown option: $value');
        words.add(value);
    }
  }
  if (result.help || words.isEmpty) return result..help = true;
  final command = words.first, name = words.length > 1 ? words[1] : null;
  if (!_commands.contains(command)) _usage('Unknown command: $command. Use moments --help.');
  if (result.workers != null && command != 'suite') _usage('--workers only applies to suite.');
  if (result.backendOnly && command != 'up') _usage('--backend-only only applies to up.');
  if ((result.debugBuild || result.headless || result.wasm) && command != 'suite') {
    _usage('--debug-build, --wasm and --headless only apply to suite.');
  }
  if ((result.debugBuild || result.wasm) && result.headless) _usage('--headless does not use a web build.');
  if (result.debugBuild && result.wasm) _usage('Choose --debug-build or --wasm.');
  result.command = command;
  if (command == 'suite') {
    final names = words.skip(1).toList();
    if (names.any((n) => !_momentName.hasMatch(n))) _usage('Usage: moments suite [name...] [--workers N]');
    if (result.base != null && !result.affected) _usage('--base requires suite --affected.');
    return result..names = names;
  }
  final named = const ['profile', 'open', 'up'].contains(command);
  if (words.length != (named ? 2 : 1) || (named && !_momentName.hasMatch(name!))) {
    _usage('Usage: moments $command${named ? ' <name>' : ''}');
  }
  result.name = name;
  if (command == 'reset' && !result.discardData) {
    _usage('Reset removes local data; use moments reset --discard-data.');
  }
  if (result.discardData && command != 'reset') _usage('--discard-data only applies to reset.');
  if (result.retryPreparation && command != 'up') _usage('--retry-preparation only applies to up.');
  if (result.device != null && command != 'up') _usage('--device only applies to up.');
  if (result.restart && command != 'refresh') _usage('--restart only applies to refresh.');
  if (result.check && command != 'refresh') _usage('--check only applies to refresh.');
  if (result.fresh && !const ['open', 'up'].contains(command)) _usage('--fresh only applies to open/up <name>.');
  if (result.fresh && result.retryPreparation) _usage('--fresh cannot be combined with --retry-preparation.');
  if (result.full && command != 'inspect') _usage('--full only applies to inspect.');
  if (result.local && command != 'status') _usage('--local only applies to status.');
  if (result.base != null && command != 'affected') _usage('--base only applies to affected and suite --affected.');
  if (result.affected) _usage('--affected only applies to suite.');
  if (result.json && const ['up', 'sync'].contains(command)) {
    _usage('$command streams logs; use status/inspect --json to observe the session.');
  }
  return result;
}

String findProject(String cwd, String? explicit) {
  if (explicit != null) return p.normalize(p.join(cwd, explicit));
  for (var dir = p.normalize(p.absolute(cwd)); ;) {
    if (File(p.join(dir, 'moments/manifest.json')).existsSync() ||
        File(p.join(dir, 'moments/backend.json')).existsSync()) {
      return dir;
    }
    final config = File(p.join(dir, '.moments.json'));
    if (config.existsSync()) {
      final value = jsonDecode(config.readAsStringSync());
      final project = value is Map ? value['project'] : null;
      if (project is! String || project.trim().isEmpty) throw const MomentsError('.moments.json must declare project.');
      return p.normalize(p.join(dir, project));
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  throw const MomentsError('No Moments project found. Enter an app directory or use --project <dir>.');
}

const _label = {
  'captured': 'CAPTURED (no final verification)',
  'passed': 'PASSED',
  'failed': 'FAILED',
  'unavailable': 'UNAVAILABLE',
  'skipped': 'NOT APPLICABLE',
};

String? _duration(Object? ms) => ms is num && ms.isFinite ? '${(ms / 1000).toStringAsFixed(2)} s' : null;
String _status(Object? status) => _label[status] ?? '$status';
final _pretty = const JsonEncoder.withIndent('  ');

String formatResult(Object? raw, CliOptions options) {
  final command = options.command;
  if (raw is List) {
    return command == 'list'
        ? raw.map((item) => '${(item as Map)['name']} — ${item['description'] ?? ''}').join('\n')
        : _pretty.convert(raw);
  }
  final value = (raw! as Map).cast<String, Object?>();
  String lines(List<Object?> items) => items.whereType<String>().where((line) => line.isNotEmpty).join('\n');
  if (command == 'capabilities') {
    final protocol = value['protocol']! as Map;
    return [
      'Moments ${protocol['version']} · ${protocol['profile']} · partial conformance',
      for (final MapEntry(:key, value: supported) in (value['capabilities']! as Map).entries)
        '  ${supported == true ? 'available' : 'missing'}: $key',
      'Engine declaration; does not prove a materialized situation or a verified journey.',
    ].join('\n');
  }
  if (command == 'graph') {
    return [
      'Declared map · no path run',
      for (final node in (value['nodes']! as List).cast<Map>())
        '  ${node['name']}${node['from'] != null ? ' ← ${node['from']}' : ' (root)'}',
    ].join('\n');
  }
  if (command == 'status' && options.local) {
    final preparation = value['preparation'] as Map?, journey = value['journey'] as Map?;
    return lines([
      'Instance: ${value['phase']} · database ${value['database']} · supervisor ${value['supervisor']}',
      if (preparation != null) 'Preparation: ${preparation['moment']} · stage ${preparation['stage']}',
      if (journey != null) 'Journey: ${journey['name']} · ${journey['phase']}',
      if (value['phase'] == 'preparation-incomplete')
        'Data kept. Use down; reset --discard-data discards this local database to rebuild it.',
      if (value['phase'] == 'reset-interrupted') 'Resume the explicit discard with moments reset --discard-data.',
      'Resource inspection; app criteria not run.',
    ]);
  }
  if (command == 'affected') {
    final base = value['base']! as Map, commit = base['commit']! as String;
    return [
      '${value['status'] == 'unavailable' ? 'UNAVAILABLE' : 'PLAN'} · ${(value['selected']! as List).length} Moments selected · ${(value['changed']! as List).length} files changed',
      'Projeto: ${value['project']}',
      'Base: ${commit.substring(0, commit.length < 12 ? commit.length : 12)} · precision: ${value['precision']}',
      for (final item in (value['selected']! as List).cast<Map>())
        '  ${switch (item['operation']) {
          'run' => 'Journey',
          'navigate' => 'Navigation without final verification',
          _ => 'Verification',
        }}: ${item['name']} · ${item['reason']}',
      if ((value['issues']! as List).isNotEmpty) 'Missing or stale declarations: run moments sync.',
      'Plan only; no criterion or gesture run. Unknown impact or a stale graph selects the whole catalog.',
    ].join('\n');
  }
  if (_label.containsKey(value['status']) && value['checks'] is List) {
    final out = [
      '${_label[value['status']]} · ${value['name'] ?? options.name ?? 'Moment'} · ${_duration(value['durationMs']) ?? 'time unavailable'}',
    ];
    if ('${value['operation'] ?? ''}'.contains('navigation')) {
      out.add('Navigation and UI capture; global effects and final criteria not verified.');
    }
    if (value['target'] != null) out.add('Device: ${(value['target']! as Map)['connected']}');
    if (value['refresh'] != null) {
      out.add(
        'Refresh ${(value['refresh']! as Map)['mode'] == 'joined' ? 'joined' : 'started'} · stage: ${value['stage']}',
      );
    }
    for (final check in (value['checks']! as List).cast<Map>()) {
      out.add('  ${_status(check['status'])}  ${check['name']}');
    }
    for (final step in ((value['steps'] as List?) ?? const []).cast<Map>()) {
      out.add('  ${_status(step['status'])}  gesto ${step['name']} · ${step['dispatch']}');
      for (final check in ((step['checks'] as List?) ?? const []).cast<Map>()) {
        if (check['status'] != 'passed') {
          out.add('  ${_status(check['status'])}  ${check['name']} · postcondition of ${step['name']}');
        }
      }
    }
    if ((value['checks']! as List).isEmpty) out.add('Criteria not run.');
    if (value['verdict'] case final Map verdict) {
      final score = verdict['acceptanceScore'] as num?;
      out.add('AVP verdict: ${verdict['outcome']}${score == null ? '' : ' · ${score.toStringAsFixed(2)}'}');
      for (final result in (verdict['results']! as List).cast<Map>()) {
        if (result['status'] != 'pass' && result['reason'] != null)
          out.add('  ${result['status']}: ${result['reason']}');
      }
    }
    final actions = value['actions'] as Map?;
    if (actions != null) {
      out.add(
        actions['status'] == 'observed'
            ? 'Observed actions: ${actions['spans']} spans in ${actions['requests']} requests${actions['truncated'] == true ? ' (truncated)' : ''}; criteria coverage not established.'
            : 'No action evidence; this does not prove nothing ran.',
      );
      for (final change in (actions['changes'] as List?) ?? const []) {
        out.add('  changed: $change');
      }
    }
    final profile = value['profile'] as Map?;
    if (profile != null) {
      final backend = profile['backend']! as Map;
      out
        ..add('Profile: ${profile['status']} · latency/queries of one instrumented local run')
        ..add(
          'Requests measured: ${backend['requestsProfiled']}/${backend['requestsObserved']} · queries observed: ${(backend['database'] as Map?)?['queries'] ?? 'unavailable'}',
        )
        ..add('Backend times may overlap; they are neither CPU time nor a production benchmark.');
      if (profile['status'] == 'partial') {
        out.add('Incomplete profile (exit 2); the journey effects may have happened. Inspect before repeating.');
      }
    }
    if (value['reason'] != null) out.add('${value['reason']}');
    final ownership = value['ownership'] as Map?;
    if (ownership != null && ownership['phase'] != 'idle') {
      out.add('Instance held (${ownership['phase']}). Inspect the effects before moments recover.');
    }
    if (value['report'] != null) out.add('Report: ${value['report']}');
    return out.join('\n');
  }
  if (command == 'reset') {
    return 'Isolated database and resume states removed. Proofs kept; the next up creates a new instance.';
  }
  if (command == 'down') return 'Instance stopped (${value['mode']}). Database and states kept.';
  if (command == 'recover') return 'Instance released. The journey effects were neither undone nor repeated.';
  if (command == 'status' || command == 'refresh') {
    final target = value['target'] as Map?, journey = value['journey'] as Map?;
    final last = journey?['lastOperation'] as Map?;
    return lines([
      'Refresh: ${value['phase']}${value['id'] != null ? ' · attempt ${value['id']}' : ''}',
      if (target != null)
        'Device: ${target['requested']}${target['connected'] == flutterTarget(target['requested']! as String).id ? '' : ' (waiting for Flutter)'}',
      if (value['phase'] == 'waiting-runtime')
        'Waiting for the first Flutter observation. Open the app; pending edits will be applied automatically.',
      if (journey != null && journey['phase'] != 'idle') 'Journey: ${journey['name']} · ${journey['phase']}',
      if (last != null)
        'Last recorded intent: ${last['operation']}${last['target'] != null ? ' · ${last['target']}' : ''} (check the effect on the backend).',
      if (const ['attention', 'expired'].contains(journey?['phase']))
        'Journey held. Use moments inspect; after checking the effects, moments recover.',
      if (value['moment'] != null) 'Moment: ${value['moment']}',
      if (_duration(value['waitMs']) != null) 'Wait after the save was seen: ${_duration(value['waitMs'])}',
      if (_duration(value['totalMs']) != null) 'Compile + resume: ${_duration(value['totalMs'])}',
      if (value['pending'] == true) 'There is a pending edit.',
      value['error'] as String?,
      if (command == 'refresh') 'Refresh requested; criteria not run. Follow it with moments status.',
    ]);
  }
  if (command == 'open') {
    return 'Moment: ${(value['state'] as Map?)?['name'] ?? options.name}\n'
        '${options.fresh ? 'Origin: initial UI recipe.\n' : ''}'
        '${value['observed'] != null ? 'Resume confirmed.' : 'Resume not confirmed yet.'}\n'
        'Use moments refresh --check to verify its criteria.';
  }
  if (command == 'inspect' && options.full) return _pretty.convert(value);
  if (command == 'inspect') {
    final criteria = value['criteria'] as Map?, sources = value['sources'] as Map?;
    final ash = sources?['ash'] as Map?;
    return [
      'Moment: ${(value['moment'] as Map?)?['name'] ?? 'none'}',
      'UI: ${(value['screen'] as Map?)?['status'] ?? 'unavailable'} (last observation, no presence probe)',
      'Backend: ${(value['backend'] as Map?)?['status'] ?? 'unavailable'}',
      if (criteria != null) ...[
        'Criteria: ${criteria['status']} (${(criteria['items']! as List).length}); not run.',
        if (ash != null) ...[
          'Ash: ${ash['file'] != null ? '${ash['file']}:${ash['line']}' : 'source unavailable'} (${ash['status']})',
          if (ash['reason'] != null) '${ash['reason']}',
        ],
        for (final path in (sources!['watched'] as List?) ?? const []) 'File: $path',
        if (sources['issue'] != null) '${sources['issue']}',
      ],
      'Use --json for details; inspecting does not run criteria.',
    ].join('\n');
  }
  return _pretty.convert(value);
}

/// Talks to the bridge of the running `moments up` of [project].
Request bridgeRequest(String project) {
  final runtimeFile = p.join(project, 'moments/.backend/.runtime.json');
  return (path, [data]) async {
    if (!File(runtimeFile).existsSync()) {
      throw const MomentsError('No active Moments instance; start one with moments up <name>.');
    }
    final session = (jsonDecode(File(runtimeFile).readAsStringSync()) as Map).cast<String, Object?>();
    final timeout = Duration(
      milliseconds: path.startsWith('/render/') || path.startsWith('/journey/')
          ? 10000
          : path == '/moments/open'
          ? 30000
          : 5000,
    );
    final client = HttpClient();
    try {
      final request = await client
          .openUrl(data == null ? 'GET' : 'POST', Uri.parse('${session['url']}$path'))
          .timeout(timeout);
      request.headers
        ..set('Authorization', 'Bearer ${session['token']}')
        ..set('Content-Type', 'application/json');
      if (data != null) request.add(utf8.encode(jsonEncode(data)));
      final response = await request.close().timeout(timeout);
      final text = await utf8.decoder.bind(response).join().timeout(timeout);
      final body = (jsonDecode(text) as Map).cast<String, Object?>();
      if (response.statusCode < 200 || response.statusCode >= 300) throw MomentsError('${body['error']}');
      return body;
    } on TimeoutException {
      throw MomentsError('The bridge did not answer $path within ${timeout.inSeconds} s.');
    } finally {
      client.close(force: true);
    }
  };
}

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Adapter? _adapter(String project) =>
    File(p.join(project, 'moments/backend.json')).existsSync() ? Adapter.load(project) : null;

List<Map<String, Object?>> _catalog(String project) {
  final adapter = _adapter(project);
  if (adapter != null) return adapter.catalog();
  final map = parseMap(File(p.join(project, 'MOMENTS.md')).readAsStringSync());
  return [
    for (final name in map.order)
      {'name': name, 'from': map.states[name]!.from, 'description': map.states[name]!.describe},
  ];
}

Future<void> _upSandbox(String project, String name, SandboxOptions options) async {
  final adapter = _adapter(project);
  if (adapter == null || !adapter.catalog().any((entry) => entry['name'] == name)) {
    throw const MomentsError('Unknown backend moment; use moments list');
  }
  await runSandbox(adapter, 'up', options: options);
}

Future<Object?> _live(String project, CliOptions options) async {
  final request = bridgeRequest(project);
  final runtime = File(p.join(project, 'moments/.backend/.runtime.json'));
  switch (options.command) {
    case 'profile':
      return checkMoment(project: project, name: options.name, request: request, profile: true);
    case 'recover':
      final current = await request('/journey/lease');
      return request('/journey/lease', {'operation': 'recover', 'journeyId': current['id'], 'acknowledge': true});
    case 'inspect':
      return request('/moments/inspect');
    case 'status':
      return request('/dev/status');
    case 'refresh':
      if (options.check) {
        return checkMoment(project: project, name: null, request: request, refresh: true, restart: options.restart);
      }
      return request('/dev/refresh', {'restart': options.restart});
    case 'list':
      return _catalog(project);
    case 'open':
      final adapter = _adapter(project);
      if (adapter != null && adapter.catalog().any((entry) => entry['name'] == options.name) && !runtime.existsSync()) {
        await _upSandbox(
          project,
          options.name!,
          SandboxOptions(initialMoment: options.name, openBrowser: true, fresh: options.fresh),
        );
        return null;
      }
      final started = DateTime.now();
      final result = await request('/moments/open', {'name': options.name, 'fresh': options.fresh});
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      Map<String, Object?>? report;
      while (DateTime.now().isBefore(deadline)) {
        report = await request('/moments/look');
        if ((report['observed'] as Map?)?['revision'] == result['revision']) break;
        await _sleep(50);
      }
      if ((report?['observed'] as Map?)?['revision'] != result['revision']) {
        throw const MomentsError('Moment saved, but no runtime reported restoration within 8 seconds.');
      }
      return {
        ...result,
        'observed': report!['observed'],
        'commandToObservedMs': DateTime.now().difference(started).inMicroseconds / 1000,
      };
    case 'up':
      await _upSandbox(
        project,
        options.name!,
        SandboxOptions(
          initialMoment: options.name,
          device: options.device,
          retryPreparation: options.retryPreparation,
          fresh: options.fresh,
          backendOnly: options.backendOnly,
        ),
      );
      return null;
    case 'sync':
      final adapter = _adapter(project);
      if (adapter == null) throw const MomentsError('This project has no Moments compiler');
      await adapter.sync();
      return null;
  }
  throw MomentsError('Unknown command: ${options.command}');
}

int _exit(Object? result) => result is Map && result['exitCode'] is int ? result['exitCode']! as int : 0;

Future<int> runCli(List<String> args, {String? cwd}) async {
  cwd ??= Directory.current.path;
  if (args case ['tools']) {
    try {
      await buildImportsTool();
      return 0;
    } on Object catch (error) {
      stderr.writeln(error is MomentsError ? error.message : '$error');
      return 2;
    }
  }
  late CliOptions options;
  void emit(Object? value, {bool pretty = true}) =>
      print(options.json ? (pretty ? _pretty.convert(value) : jsonEncode(value)) : formatResult(value, options));
  try {
    options = parseArgs(args);
    if (options.help) {
      print(options.json ? jsonEncode({'help': help}) : help);
      return 0;
    }
    if (options.command == 'capabilities') {
      emit(capabilities());
      return 0;
    }
    final project = findProject(cwd, options.project);
    if (options.command == 'suite') return await _suite(project, options);
    if (options.command == 'graph') {
      final manifest = readManifest(p.join(project, 'moments/manifest.json'));
      emit(momentGraph((manifest['moments']! as Map).cast()));
      return 0;
    }
    if (options.command == 'status' && options.local) {
      emit(inspectInstance(project));
      return 0;
    }
    if (options.command == 'reset') {
      emit(await resetInstance(project, discardData: options.discardData));
      return 0;
    }
    if (options.command == 'down') {
      emit(await downInstance(project));
      return 0;
    }
    final manifestFile = File(p.join(project, 'moments/manifest.json'));
    if (options.command != 'sync' && !manifestFile.existsSync()) {
      throw const MomentsError('The selected app has no moments/manifest.json.');
    }
    if (options.command == 'affected') {
      final result = await affectedMoments(project, base: options.base ?? 'HEAD');
      emit(result);
      return _exit(result);
    }
    final compact = options.command == 'inspect' && !options.full;
    final manifestText = compact ? manifestFile.readAsStringSync() : null;
    var result = await _live(project, options);
    if (const ['up', 'sync'].contains(options.command) || (options.command == 'open' && result == null)) {
      return exitCode;
    }
    if (compact) {
      if (manifestFile.readAsStringSync() != manifestText) {
        throw const MomentsError('The declaration changed during inspection; run it again.');
      }
      result = compactInspection((result! as Map).cast(), (jsonDecode(manifestText!) as Map).cast());
    }
    emit(result);
    return _exit(result);
  } on Object catch (error) {
    final reason = error is MomentsError ? error.message : '$error';
    final result = {'status': 'unavailable', 'exitCode': 2, 'reason': reason};
    print(args.contains('--json') ? _pretty.convert(result) : 'UNAVAILABLE · $reason');
    return 2;
  }
}

String _mb(Object? bytes) => '${((bytes as num? ?? 0) / 1048576).round()} MB';

Future<int> _suite(String project, CliOptions options) async {
  final result = await runSuite(
    project: project,
    names: options.names,
    workers: options.workers ?? 4,
    mode: options.debugBuild
        ? 'debug'
        : options.wasm
        ? 'wasm'
        : 'profile',
    runtime: options.headless ? 'headless' : 'browser',
    affectedBase: options.affected ? (options.base ?? 'HEAD') : null,
    onEvent: (event) {
      if (options.json) return;
      final reason = event['reason'];
      switch (event['phase']) {
        case 'backend':
          print('Suite: no backend open; starting a temporary one (--backend-only)…');
        case 'affected':
          print(
            'Suite: ${event['moments']} Moments affected (${event['precision']}${reason != null ? ': $reason' : ''})',
          );
        case 'compile':
          print('Suite: compiling the ${event['mode']} web artifact (once per code version)…');
        case 'headless':
          print('Suite: starting headless workers (flutter_tester, compiles the app once)…');
        case 'run':
          print(
            'Suite: ${event['moments']} Moments on ${event['workers']} workers ${event['runtime'] == 'headless' ? 'headless' : '· browser · port ${event['port']}'}',
          );
        case 'moment':
          final status = event['status'];
          print(
            '${_status(status)} · ${event['name']} · ${_duration(event['durationMs']) ?? '-'} · w${event['worker']}'
            '${reason != null && status != 'passed' ? '${status == 'skipped' ? ' · ' : '\n  '}$reason' : ''}',
          );
      }
    },
  );
  if (options.json) {
    print(_pretty.convert(result));
  } else {
    final headless = result['runtime'] == 'headless';
    final memory = (result['peakMemory'] as Map?) ?? const {};
    final skipped = result['skipped'];
    print(
      [
        'Suite: ${_status(result['status'])} · ${result['moments']} Moments${skipped is int && skipped > 0 ? ' ($skipped not applicable)' : ''} · ${_duration(result['wallMs'])} '
            '(serial sum ${_duration(result['serialMs'])}; ${headless ? 'worker startup ${_duration(result['headlessStartupMs'])}' : 'build ${result['cached'] == true ? 'cached' : _duration(result['buildMs'])}'})',
        'Peak memory (PSS): ${headless ? 'flutter_tester ${_mb(memory['flutterTesterBytes'])}' : 'browser ${_mb(memory['browserBytes'])}'} · suite ${_mb(memory['suiteBytes'])}',
        'Summary: ${result['directory']}/summary.json',
      ].join('\n'),
    );
  }
  return _exit(result);
}
