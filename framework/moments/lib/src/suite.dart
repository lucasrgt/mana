import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show assertOwned, uuidV4;
import 'package:path/path.dart' as p;

import 'adapter.dart';
import 'affected.dart';
import 'backend_recipes.dart';
import 'bridge.dart';
import 'canonical.dart';
import 'check.dart';
import 'chromium.dart';
import 'dart_sources.dart';
import 'errors.dart';
import 'headless_runtime.dart';
import 'inspect.dart';
import 'json.dart';
import 'manifest.dart';
import 'memory.dart';
import 'paths.dart';
import 'runtime.dart';
import 'services.dart';
import 'web_actor.dart';

/// The command that runs this program again (compiled or `dart run`).
List<String> selfCommand() {
  final script = Platform.script.toFilePath();
  return script.endsWith('.dart') ? [Platform.resolvedExecutable, script] : [Platform.resolvedExecutable];
}

final class _SupervisorDevelopment implements Development {
  _SupervisorDevelopment(this._status, this.inspect);
  final Map<String, Object?> Function() _status;
  @override
  final Future<Map<String, Object?>> Function()? inspect;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => null;
  @override
  Future<void> Function()? get stop => null;
  @override
  Renewal? get renewal => null;
  @override
  Map<String, Object?> status() => _status();
}

final class _Worker implements HeadlessWorker {
  _Worker(this.index, this.apiUrl);
  @override
  final int index;
  @override
  final String apiUrl;
  final id = uuidV4();
  late Map<String, Object?> current;
  late BackendRecipes recipes;
  late Bridge bridge;
  @override
  String get bridgeUrl => bridge.url;
  @override
  String get bridgeToken => bridge.token;
  @override
  final errors = <String>[];
  ChromiumPage? page;
  ChromiumContext? context;
  Object? renderer;
  double restartMs = 0;

  Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 60);
    try {
      final request = await client.openUrl(data == null ? 'GET' : 'POST', Uri.parse(bridge.url + path));
      request.headers
        ..set('Authorization', 'Bearer ${bridge.token}')
        ..set('Content-Type', 'application/json');
      if (data != null) request.add(utf8.encode(jsonEncode(data)));
      final response = await request.close().timeout(const Duration(seconds: 60));
      final text = await utf8.decoder.bind(response).join();
      Map<String, Object?> body;
      try {
        body = text.isEmpty ? {} : (jsonDecode(text) as Map).cast();
      } on Object {
        body = {};
      }
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw MomentsError('${body['error'] ?? 'bridge ${response.statusCode}'}');
      return body;
    } finally {
      client.close(force: true);
    }
  }
}

/// Runs many Moments at once against the backend of a running `moments up`
/// (preferably `--backend-only`). Browser runtime: one compiled web artifact,
/// one static server, headless browsers, a fresh context per Moment. Headless
/// runtime: the app under flutter_tester. Fixtures come from the same backend
/// recipes and every Moment still goes through [checkMoment], so criteria,
/// source identity and proofs are the same as `moments run`.
Future<Map<String, Object?>> runSuite({
  required String project,
  List<String>? names,
  int workers = 4,
  String mode = 'profile',
  int? browsers,
  String runtime = 'browser',
  String? affectedBase,
  void Function(Map<String, Object?> event)? onEvent,
}) async {
  final emit = onEvent ?? (_) {};
  if (!const ['profile', 'debug', 'wasm'].contains(mode))
    throw const MomentsError('Build mode must be profile, debug or wasm');
  if (!const ['browser', 'headless'].contains(runtime)) throw const MomentsError('Runtime must be browser or headless');
  final adapter = Adapter.load(project);
  final manifestFile = adapter.manifestFile;
  final manifest = readManifest(manifestFile);
  final moments = (manifest['moments']! as Map).cast<String, Object?>();
  var selected = names?.isNotEmpty == true ? names! : moments.keys.toList();
  Map<String, Object?>? selection;
  final framework = _frameworkDigest(), frameworkFile = p.join(project, 'moments/.suite/framework.json');
  if (affectedBase != null) {
    if (names?.isNotEmpty == true) throw const MomentsError('Choose named Moments or --affected, not both');
    final plan = await affectedMoments(project, base: affectedBase);
    final known = File(frameworkFile).existsSync()
        ? (jsonDecode(File(frameworkFile).readAsStringSync()) as Map)['digest']
        : null;
    if (plan['status'] != 'planned') {
      selection = {'precision': 'whole-catalog', 'reason': 'affected plan unavailable'};
    } else if (known != framework) {
      selection = {
        'precision': 'whole-catalog',
        'reason': "Mana framework changed since the last green suite (outside this app's git)",
      };
    } else {
      selected = [for (final item in (plan['selected']! as List).cast<Map>()) item['name']! as String];
      selection = {
        'precision': plan['precision'],
        'base': (plan['base'] as Map?)?['commit'],
        'omitted': (plan['omitted']! as List).length,
      };
    }
    emit({'phase': 'affected', ...selection, 'moments': selected.length});
    if (selected.isEmpty) {
      return {
        'version': 1,
        'status': 'passed',
        'moments': 0,
        'selection': selection,
        'results': <Object?>[],
        'exitCode': 0,
        'directory': null,
        'wallMs': 0,
        'serialMs': 0,
        'peakMemory': <String, Object?>{},
        'runtime': runtime,
      };
    }
  }
  for (final name in selected) {
    if (!moments.containsKey(name)) throw MomentsError('Unknown Moment: $name');
  }
  if (workers < 1 || workers > 8) throw const MomentsError('Use 1–8 workers');
  if (workers > selected.length) workers = selected.length;

  final directory = p.join(project, 'moments/.backend');
  final instanceFile = p.join(directory, 'instance.json'), runtimeFile = p.join(directory, '.runtime.json');
  _TemporaryBackend? temporary;
  Timer? poller;
  if (!File(p.join(directory, 'running.json')).existsSync() || !File(runtimeFile).existsSync()) {
    emit({'phase': 'backend'});
    temporary = await _TemporaryBackend.start(project: project, directory: directory, name: adapter.initialMoment);
  }
  Map<String, Object?>? status;
  Object? statusError;
  try {
    final instance = (jsonDecode(File(instanceFile).readAsStringSync()) as Map).cast<String, Object?>();
    Future<void> assertAvailable() async {
      if ((assertOwned(instance)['State'] as Map?)?['Running'] != true)
        throw const MomentsError('Owned backend is not running');
    }

    await assertAvailable();
    final supervisor = (jsonDecode(File(runtimeFile).readAsStringSync()) as Map).cast<String, Object?>();
    Future<void> poll() async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      try {
        final request = await client.getUrl(Uri.parse('${supervisor['url']}/dev/status'));
        request.headers.set('Authorization', 'Bearer ${supervisor['token']}');
        final response = await request.close().timeout(const Duration(seconds: 2));
        final text = await utf8.decoder.bind(response).join();
        if (response.statusCode != 200) throw MomentsError('supervisor ${response.statusCode}');
        status = (jsonDecode(text) as Map).cast<String, Object?>()..remove('journey');
        statusError = null;
      } on Object catch (error) {
        statusError = error;
      } finally {
        client.close(force: true);
      }
    }

    bool settled() {
      final value = status;
      return value != null &&
          const ['idle', 'ready'].contains(value['phase']) &&
          value['pending'] != true &&
          value['held'] != true &&
          ((value['services'] as List?) ?? const []).cast<Map>().every(
            (s) => s['running'] == true && s['phase'] == 'ready' && s['codeChanged'] != true,
          );
    }

    final deadline = DateTime.now().add(const Duration(minutes: 5));
    while (true) {
      await poll();
      if (settled()) break;
      if (DateTime.now().isAfter(deadline)) {
        throw MomentsError('Backend did not settle: ${status?['error'] ?? statusError ?? status?['phase']}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    poller = Timer.periodic(const Duration(milliseconds: 250), (_) => unawaited(poll()));

    final run = p.join(
      project,
      'moments/.suite',
      'run-${DateTime.now().toUtc().toIso8601String().replaceAll(RegExp('[:.]'), '-')}',
    );
    Directory(run).createSync(recursive: true);
    Process.runSync('chmod', ['700', run]);
    void log(String file, String text) =>
        File(p.join(run, file)).writeAsStringSync(text.endsWith('\n') ? text : '$text\n', mode: FileMode.append);
    final resources = <Future<void> Function()>[];
    final browserPool = <Chromium>[];
    HeadlessRuntime? headless;
    var peakBrowser = 0, peakSuite = 0;
    Timer? sampler;
    final started = nowMs();
    try {
      ({String directory, String sources, bool cached, double buildMs})? artifact;
      int? port;
      if (runtime == 'browser') {
        emit({'phase': 'build'});
        artifact = await _buildArtifact(
          project: project,
          manifest: manifest,
          adapter: adapter,
          instance: instance,
          mode: mode,
          emit: emit,
        );
        final sources = DartSources(
          project,
          (manifest['watch']! as List).cast<String>(),
        ).snapshot(fresh: true)['digest'];
        if (sources != artifact.sources)
          throw const MomentsError('Dart sources changed after the build; run the suite again');
        port = await isFreePort(adapter.webPort) ? adapter.webPort : adapter.suitePort;
        if (port == null || !await isFreePort(port)) {
          throw const MomentsError(
            'No free web port: stop the Flutter dev runtime (up --backend-only) or declare a free suitePort allowed by the backend CORS',
          );
        }
      } else if (adapter.headless == null) {
        throw const MomentsError(
          'moments/backend.json must declare headless: {file, function} for the headless runtime',
        );
      }
      final pool = <_Worker>[];
      Future<void> Function(_Worker worker)? restart;
      for (var index = 0; index < workers; index++) {
        final worker = _Worker(index, instance['apiUrl']! as String)
          ..current = {...instance, 'launch': null, 'preparedMoment': null};
        worker.recipes = BackendRecipes(
          manifestFile: manifestFile,
          recipes: adapter.recipes(),
          instance: () => worker.current,
          assertAvailable: assertAvailable,
          commit: (launch, {base, preparedMoment}) async {
            worker.current = {
              ...worker.current,
              'launch': launch,
              'baseRecipe': ?base,
              'preparedMoment': ?preparedMoment,
            };
          },
        );
        final resolve = adapter.resolveInput;
        worker.bridge = await Bridge.start(
          directory: p.join(project, 'live-ui'),
          sessionDirectory: p.join(run, 'worker-$index'),
          port: 0,
          momentsOptions: MomentsOptions(
            directory: p.join(project, 'moments'),
            sessionFile: p.join(run, 'worker-$index', 'ui-session.json'),
            manifestFile: manifestFile,
            resumeOnOpen: false,
            prepare: worker.recipes.prepare,
            afterPreparedOpen: (_) => restart!(worker),
          ),
          bootstrap: () => {
            ...((worker.current['launch'] as Map?) ?? const {}).cast<String, Object?>(),
            'apiUrl': instance['apiUrl'],
          },
          resolveInput: resolve == null ? null : (reference) => resolve(worker.current, reference),
          development: _SupervisorDevelopment(
            () => status ?? {'phase': 'error', 'error': '${statusError ?? 'supervisor unavailable'}'},
            () async {
              final moment = worker.bridge.moments!.inspect();
              final name = (moment['state'] as Map?)?['name'] as String?;
              if (!worker.recipes.declared(name)) throw const MomentsError('Moment has no declared backend recipe');
              return worker.recipes.inspect(
                name!,
                context: {'projection': (moment['observed'] as Map?)?['projection']},
              );
            },
          ),
        );
        resources.add(worker.bridge.close);
        pool.add(worker);
      }
      WebActor? server;
      if (runtime == 'browser') {
        server = await WebActor.start(
          artifact: artifact!.directory,
          port: port!,
          apiUrl: instance['apiUrl']! as String,
          immutable: true,
          crossOriginIsolated: mode == 'wasm',
          bridgeUrl: workers == 1 ? pool.single.bridge.url : null,
          bridgeToken: workers == 1 ? pool.single.bridge.token : null,
          surfaces: workers == 1
              ? null
              : {
                  for (final w in pool) w.id: {'bridgeUrl': w.bridge.url, 'bridgeToken': w.bridge.token},
                },
        );
        resources.add(server.close);
        // Measured on 16 cores: more browsers cost memory without speed,
        // because software rasterization saturates the CPU first. One by default.
        final browserCount = workers < (browsers ?? 1) ? workers : (browsers ?? 1);
        for (var index = 0; index < browserCount; index++) {
          final browser = await Chromium.launch(
            directory: p.join(run, 'browser-$index'),
            log: (text) => log('chromium-$index.log', text),
          );
          browserPool.add(browser);
          resources.add(browser.close);
        }
      } else {
        emit({'phase': 'headless'});
        final entry = adapter.headless!;
        headless = await HeadlessRuntime.start(
          project: project,
          run: run,
          workers: pool,
          entry: entry,
          defines: {
            ...adapter.flutterDefines(instance),
            'MANA_MOMENTS': 'true',
            'MANA_MOMENT_BOOTSTRAP': 'true',
            'MANA_RUNTIME_BOOTSTRAP': 'true',
          },
          log: (text) => log('headless.log', text),
        );
        resources.add(headless.close);
      }
      sampler = Timer.periodic(const Duration(milliseconds: 500), (_) {
        final browserBytes = headless?.memory() ?? browserPool.fold<int>(0, (sum, b) => sum + b.memory());
        if (browserBytes > peakBrowser) peakBrowser = browserBytes;
        final suite = treeMemory(pid) - browserBytes;
        if (suite > peakSuite) peakSuite = suite;
      });

      Future<void> openTab(_Worker worker) async {
        await worker.page?.close();
        worker.page = null;
        worker.context ??= await browserPool[worker.index % browserPool.length].context();
        await worker.context!.wipe(server!.url);
        worker.page = await worker.context!.page(
          onError: (text) {
            worker.errors.add(text);
            log('worker-${worker.index}.log', text);
          },
        );
        final url = Uri.parse(server!.url).replace(queryParameters: workers > 1 ? {'momentsActor': worker.id} : null);
        await worker.page!.navigate(url.toString());
      }

      // A Moment's launch (fixture account, route) is read once at app start,
      // so every prepared open restarts the runtime.
      restart = (worker) async {
        final begun = nowMs();
        final checkpoint = worker.bridge.moments!.checkpoint();
        if (headless != null) {
          await headless.restart(worker);
        } else {
          await openTab(worker);
        }
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (worker.bridge.moments!.restorationAfter(checkpoint) == null) {
          if (DateTime.now().isAfter(deadline)) throw const MomentsError('The app did not restore the prepared Moment');
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        if (headless == null && worker.renderer == null) {
          try {
            worker.renderer = await worker.page!.evaluate(
              "({wasm:performance.getEntriesByType('resource').some(r=>r.name.endsWith('/main.dart.wasm')),isolated:globalThis.crossOriginIsolated})",
            );
          } on Object {
            worker.renderer = null;
          }
        }
        worker.restartMs += nowMs() - begun;
      };

      // A failed journey keeps its ownership for inspection. Its effects live
      // in unique, disposable fixtures, so the worker acknowledges and releases
      // it (recorded on the result). Ownership still active means an operation
      // is in flight: the worker retires instead of guessing.
      Future<bool?> release(_Worker worker) async {
        for (var attempt = 0; attempt < 40; attempt++) {
          Map<String, Object?>? lease;
          try {
            lease = await worker.request('/journey/lease');
          } on Object {
            lease = null;
          }
          if (lease == null || lease['phase'] == 'idle') return false;
          if (const ['attention', 'expired'].contains(lease['phase'])) {
            await worker.request('/journey/lease', {
              'operation': 'recover',
              'journeyId': lease['id'],
              'acknowledge': true,
            });
            return true;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        return null;
      }

      final history = _durations(project);
      final queue = [...selected]..sort((a, b) => (history[b] ?? 0).compareTo(history[a] ?? 0));
      final results = <Map<String, Object?>>[];
      emit({
        'phase': 'run',
        'runtime': runtime,
        'workers': workers,
        'browsers': browserPool.length,
        'moments': queue.length,
        'port': port,
      });
      await Future.wait([
        for (final worker in pool)
          () async {
            while (queue.isNotEmpty) {
              final name = queue.removeAt(0);
              final scene = (moments[name]! as Map).cast<String, Object?>();
              final platforms = (scene['platforms'] as List?)?.cast<String>();
              if (platforms != null && !platforms.contains(headless != null ? 'native' : 'web')) {
                final entry = {
                  'name': name,
                  'worker': worker.index,
                  'status': 'skipped',
                  'reason': 'declared for ${platforms.join(', ')} only',
                };
                results.add(entry);
                emit({'phase': 'moment', ...entry});
                continue;
              }
              final journey = ((scene['steps'] as List?)?.length ?? 0) > 0;
              worker.errors.clear();
              worker.restartMs = 0;
              Map<String, Object?> result;
              try {
                if (!journey) await worker.request('/moments/open', {'name': name, 'fresh': true, 'prepare': true});
                result = await checkMoment(
                  project: project,
                  name: name,
                  request: worker.request,
                  journey: journey,
                  manifestFile: manifestFile,
                );
              } on Object catch (error) {
                result = {
                  'status': 'unavailable',
                  'reason': error is MomentsError ? error.message : '$error',
                  'checks': <Object?>[],
                };
              }
              bool? recovered = false;
              if (result['status'] != 'passed') {
                Map<String, Object?>? look;
                try {
                  look = await worker.request('/moments/look');
                } on Object {
                  look = null;
                }
                log(
                  'worker-${worker.index}.log',
                  '$name: ${result['status']} · ${result['reason'] ?? ''} · last observed ${jsonEncode((look?['observed'] as Map?)?['projection'])} (${look?['status'] ?? 'unknown'})',
                );
                recovered = await release(worker);
              }
              final reasons = [
                ?result['reason'],
                for (final step in ((result['steps'] as List?) ?? const []).cast<Map>())
                  if (step['dispatchReason'] != null) 'step ${step['name']}: ${step['dispatchReason']}',
              ].where((r) => '$r'.isNotEmpty).join(' · ');
              final entry = {
                'name': name,
                'worker': worker.index,
                'status': result['status'],
                'durationMs': result['durationMs'],
                'restartMs': worker.restartMs.round(),
                'report': result['report'],
                'checks': result['checks'],
                if (reasons.isNotEmpty) 'reason': reasons,
                if (recovered == true) 'ownershipRecovered': true,
                if (worker.errors.isNotEmpty) 'pageErrors': worker.errors.take(3).toList(),
              };
              results.add(entry);
              emit({'phase': 'moment', ...entry});
              if (recovered == null) {
                log('worker-${worker.index}.log', 'retired: journey ownership still active');
                break;
              }
            }
            await worker.page?.close();
            worker.page = null;
            await worker.context?.close();
            worker.context = null;
          }(),
      ]);
      final wallMs = nowMs() - started;
      final order = moments.keys.toList();
      results.sort((a, b) => order.indexOf(a['name']! as String).compareTo(order.indexOf(b['name']! as String)));
      final passed = results.every((r) => const ['passed', 'skipped'].contains(r['status']));
      final summary = <String, Object?>{
        'version': 1,
        'status': passed
            ? 'passed'
            : results.any((r) => r['status'] == 'failed')
            ? 'failed'
            : 'unavailable',
        'runtime': runtime,
        'workers': workers,
        if (headless != null)
          'headlessStartupMs': headless.startupMs
        else ...{
          'browsers': browserPool.length,
          'mode': mode,
          'buildMs': artifact!.buildMs,
          'cached': artifact.cached,
          'renderer': pool.first.renderer,
        },
        'moments': results.length,
        'wallMs': wallMs,
        'serialMs': results.fold<num>(0, (sum, r) => sum + ((r['durationMs'] as num?) ?? 0)),
        'skipped': results.where((r) => r['status'] == 'skipped').length,
        'peakMemory': {
          headless != null ? 'flutterTesterBytes' : 'browserBytes': peakBrowser,
          'suiteBytes': peakSuite,
          'measure': 'PSS',
        },
        'results': results,
        'scope': headless != null
            ? 'Headless widget runtime (flutter_tester, test font, no web renderer); app remounted with in-memory platform state per Moment. Same recipes, gestures, criteria and proofs as moments run; backend data is not isolated between workers beyond unique fixtures.'
            : 'Fixtures from the shared backend recipes; one compiled web artifact (profile by default, debug on request); site data wiped and verified empty before every Moment. Same criteria and proofs as moments run; backend data is not isolated between workers beyond unique fixtures.',
        'selection': ?selection,
      };
      File(p.join(run, 'summary.json')).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(summary)}\n');
      if (summary['status'] == 'passed') {
        File(
          frameworkFile,
        ).writeAsStringSync('${jsonEncode({'digest': framework, 'at': DateTime.now().toUtc().toIso8601String()})}\n');
      }
      return {
        ...summary,
        'directory': run,
        'exitCode': const {'passed': 0, 'failed': 1, 'unavailable': 2}[summary['status']],
      };
    } finally {
      sampler?.cancel();
      for (final close in resources.reversed) {
        try {
          await close();
        } on Object {
          // Best effort.
        }
      }
    }
  } finally {
    poller?.cancel();
    await temporary?.stop();
  }
}

/// A suite without a running backend opens a backend-only instance for its
/// own duration and closes it afterwards; its data and image stay for the
/// next run.
final class _TemporaryBackend {
  _TemporaryBackend._(this._child, this._exited);
  final Process _child;
  final Future<int> _exited;
  var _done = false;

  static Future<_TemporaryBackend> start({
    required String project,
    required String directory,
    required String name,
  }) async {
    final suite = Directory(p.join(project, 'moments/.suite'))..createSync(recursive: true);
    final file = File(p.join(suite.path, 'backend.log'))..writeAsStringSync('');
    final self = selfCommand();
    final child = await Process.start(self.first, [
      ...self.skip(1),
      'up',
      name,
      '--backend-only',
      '--project',
      project,
    ]);
    final sink = file.openWrite(mode: FileMode.append);
    unawaited(child.stdout.forEach(sink.add));
    unawaited(child.stderr.forEach(sink.add));
    var exited = false;
    final exit = child.exitCode.then((code) {
      exited = true;
      return code;
    });
    final backend = _TemporaryBackend._(child, exit);
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (!(File(p.join(directory, 'running.json')).existsSync() &&
        File(p.join(directory, '.runtime.json')).existsSync() &&
        file.readAsStringSync().contains('backend only'))) {
      if (exited) throw MomentsError('The temporary backend exited; inspect ${file.path}');
      if (DateTime.now().isAfter(deadline)) {
        await backend.stop();
        throw MomentsError('The temporary backend did not start; inspect ${file.path}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return backend;
  }

  Future<void> stop() async {
    if (_done) return;
    _done = true;
    _child.kill(ProcessSignal.sigint);
    await _exited.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        _child.kill(ProcessSignal.sigterm);
        return _exited;
      },
    );
  }
}

/// Artifacts are keyed by the resolved Dart sources and defines, so an
/// unchanged app reuses its build and any edit compiles exactly once.
Future<({String directory, String sources, bool cached, double buildMs})> _buildArtifact({
  required String project,
  required Manifest manifest,
  required Adapter adapter,
  required Map<String, Object?> instance,
  required String mode,
  required void Function(Map<String, Object?> event) emit,
}) async {
  final watch = (manifest['watch']! as List).cast<String>();
  final sources = DartSources(project, watch).snapshot(fresh: true)['digest']! as String;
  final defines = {
    ...adapter.flutterDefines(instance),
    'MANA_MOMENTS': 'true',
    'MANA_MOMENT_BOOTSTRAP': 'true',
    'MANA_RUNTIME_BOOTSTRAP': 'true',
  };
  final key = hashText(
    jsonEncode({'sources': sources, 'defines': defines, 'mode': mode, 'entrypoint': adapter.entrypoint}),
  ).substring(0, 24);
  final root = p.join(project, 'moments/.suite'), directory = p.join(root, 'web-$key');
  if (File(p.join(directory, '.complete')).existsSync())
    return (directory: directory, sources: sources, cached: true, buildMs: 0.0);
  Directory(root).createSync(recursive: true);
  for (final entry in Directory(root).listSync()) {
    final name = p.basename(entry.path);
    if (name.startsWith('web-') && name != 'web-$key' && File(p.join(entry.path, '.$mode')).existsSync())
      entry.deleteSync(recursive: true);
  }
  final temporary = Directory('$directory.tmp-$pid');
  if (temporary.existsSync()) temporary.deleteSync(recursive: true);
  emit({'phase': 'compile', 'key': key, 'mode': mode});
  final started = nowMs();
  final result = await Process.run('flutter', [
    'build',
    'web',
    if (mode == 'wasm') ...['--profile', '--wasm'] else '--$mode',
    '--no-pub',
    '--no-web-resources-cdn',
    '--no-wasm-dry-run',
    '-o',
    temporary.path,
    if (adapter.entrypoint != null) ...['-t', adapter.entrypoint!],
    for (final MapEntry(:key, :value) in defines.entries) '--dart-define=$key=$value',
  ], workingDirectory: project);
  if (result.exitCode != 0) {
    if (temporary.existsSync()) temporary.deleteSync(recursive: true);
    final output = '${result.stdout}${result.stderr}';
    throw MomentsError(
      'flutter build web failed:\n${output.length > 2000 ? output.substring(output.length - 2000) : output}',
    );
  }
  if (DartSources(project, watch).snapshot(fresh: true)['digest'] != sources) {
    temporary.deleteSync(recursive: true);
    throw const MomentsError('Dart sources changed during the build; run the suite again');
  }
  File(p.join(temporary.path, '.$mode')).writeAsStringSync('');
  File(
    p.join(temporary.path, '.complete'),
  ).writeAsStringSync('${jsonEncode({'sources': sources, 'defines': defines.keys.toList()})}\n');
  temporary.renameSync(directory);
  return (directory: directory, sources: sources, cached: false, buildMs: nowMs() - started);
}

/// Longest first: the slowest Moments start early, so the wall time
/// approaches the longest single Moment instead of a tail of stragglers.
Map<String, num> _durations(String project) {
  final directory = Directory(p.join(project, 'moments/.proofs'));
  final seen = <String, num>{};
  if (!directory.existsSync()) return seen;
  final files = [
    for (final entry in directory.listSync().whereType<File>())
      if (entry.path.endsWith('.json')) entry.path,
  ]..sort();
  for (final file in files.skip(files.length > 400 ? files.length - 400 : 0)) {
    try {
      final report = jsonDecode(File(file).readAsStringSync()) as Map;
      if (report['name'] is String && report['durationMs'] is num)
        seen[report['name'] as String] = report['durationMs'] as num;
    } on Object {
      // A partial or foreign file.
    }
  }
  return seen;
}

/// The framework may live outside the app's Git checkout, where `affected`
/// cannot see it; its sources are fingerprinted instead.
String _frameworkDigest() {
  final root = p.dirname(momentsRoot());
  return sourceFingerprint(root, [
    for (final path in [
      'moments/lib',
      'moments/bin',
      'flutter/live_ui/lib',
      'flutter/mana_command/lib',
      'ash/moments/lib',
    ])
      p.join(root, path),
  ]);
}
