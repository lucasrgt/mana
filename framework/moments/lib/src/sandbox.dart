import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mana/mana.dart' show assertOwned, databaseDocker, findOwnedDatabase, savePrivateState;
import 'package:path/path.dart' as p;

import 'adapter.dart';
import 'android_transport.dart';
import 'backend_recipes.dart';
import 'bridge.dart';
import 'down.dart';
import 'errors.dart';
import 'flutter_machine.dart';
import 'flutter_target.dart';
import 'inspect.dart';
import 'journey_lease.dart';
import 'json.dart';
import 'lifecycle.dart';
import 'manifest.dart';
import 'preparation_retry.dart';
import 'protocol.dart';
import 'renewal.dart';
import 'reset.dart';
import 'runtime.dart';
import 'services.dart';
import 'session_projection.dart';
import 'watch.dart';

/// How one `moments up` was asked to run.
final class SandboxOptions {
  const SandboxOptions({
    this.initialMoment,
    this.fresh = false,
    this.retryPreparation = false,
    this.backendOnly = false,
    this.device,
    this.watch = true,
    this.openBrowser = false,
  });
  final String? initialMoment;
  final bool fresh, retryPreparation, backendOnly, watch, openBrowser;
  final String? device;
}

const _label = 'dev.moments.owner';
Map<String, Object?> _read(String path) => (jsonDecode(File(path).readAsStringSync()) as Map).cast();

String _hex(int bytes) {
  final random = Random.secure();
  return [for (var i = 0; i < bytes; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

Future<void> _assertPortsFree(List<int> ports) async {
  for (final port in ports) {
    await assertFreePort(port);
  }
}

/// Applies backend edits while no journey owns the instance. A failed compile
/// keeps the previous server and reports the error until the next edit.
final class _BackendWatch {
  _BackendWatch(this.services, this.idle) {
    _applied = services.fingerprint();
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
  }
  final Services services;
  final bool Function() idle;
  String phase = 'ready';
  String? error;
  bool _busy = false;
  late String _applied;
  late final Timer _timer;

  Future<void> _tick() async {
    if (_busy) return;
    final next = services.fingerprint();
    if (next == _applied || !idle()) return;
    _busy = true;
    phase = 'compiling';
    try {
      await services.ensure();
      phase = 'ready';
      error = null;
    } on Object catch (failure) {
      phase = 'error';
      error = failure is MomentsError ? failure.message : '$failure';
    } finally {
      _applied = next;
      _busy = false;
    }
  }

  Map<String, Object?> status() => {
    'phase': phase,
    'error': error,
    'pending': services.fingerprint() != _applied,
    'held': false,
  };
  void close() => _timer.cancel();
}

/// The renewal exists once Flutter is supervised; the bridge starts earlier.
final class _LateRenewal implements Renewal {
  _LateRenewal(this._renewal, this._moments);
  final RenewalCoordinator? Function() _renewal;
  final List<String> _moments;
  @override
  bool canRenew(String name) => _moments.contains(name);
  @override
  Map<String, Object?> status() => _renewal()?.status() ?? {'phase': 'starting'};
  @override
  Map<String, Object?> start(Object? name) =>
      (_renewal() ?? (throw const MomentsError('Renewal is not ready'))).start(name);
}

final class _Development implements Development {
  _Development({
    required this.statusFn,
    required this.inspect,
    required this.refresh,
    required this.stop,
    required this.renewal,
  });
  final Map<String, Object?> Function() statusFn;
  @override
  final Future<Map<String, Object?>> Function()? inspect;
  @override
  final Map<String, Object?> Function(Map<String, Object?> input)? refresh;
  @override
  final Future<void> Function()? stop;
  @override
  final Renewal? renewal;
  @override
  Map<String, Object?> status() => statusFn();
}

/// `moments up|look|reset` for one app: its owned PostgreSQL, its backend
/// services, the bridge and (unless backend-only) `flutter run --machine`.
Future<void> runSandbox(Adapter adapter, String operation, {SandboxOptions options = const SandboxOptions()}) async {
  final services0 = adapter.services();
  validateServices(services0);
  final project = adapter.project, name = adapter.name;
  final apiPort = adapter.apiPort,
      webPort = adapter.webPort,
      bridgePort = adapter.bridgePort,
      database = adapter.database;
  final target = flutterTarget(options.device ?? 'web-server', webPort);
  final backendOnly = options.backendOnly;
  if (backendOnly && !target.web) throw const MomentsError('--backend-only serves web suites; omit --device');
  if (target.device == 'linux' && !Platform.isLinux) throw const MomentsError('The linux device requires a Linux host');
  final directory = p.join(project, 'moments', '.backend');
  Directory(directory).createSync(recursive: true);
  Process.runSync('chmod', ['700', directory]);
  final manifest = p.join(directory, 'instance.json'), lock = p.join(directory, 'running.json');
  final instance = File(manifest).existsSync() ? _read(manifest) : null;
  if (operation == 'look') {
    if (instance == null) throw const MomentsError('Run moment up first');
    final container = assertOwned(instance);
    final running = (container['State'] as Map?)?['Running'] == true;
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'name': name,
        'container': instance['container'],
        'running': running,
        'apiUrl': instance['apiUrl'],
        'webUrl': instance['webUrl'],
        if (!running) ...{
          'projection': (instance['launch'] as Map?)?['projection'],
          'status': 'stopped; projection is last seed, not current observation',
        },
      }),
    );
    return;
  }
  if (File(lock).existsSync()) {
    throw MomentsError(
      'Moment already running (or interrupted): $lock. Use moments down to stop or recover the owned instance.',
    );
  }
  if (operation == 'reset') {
    await resetInstance(project, discardData: true);
    stdout.writeln('Owned database removed. Run moments up $name to rebuild its declared base.');
    return;
  }
  if (operation != 'up') throw const MomentsError('Expected up, look or reset');
  final initialMoment = options.initialMoment ?? adapter.initialMoment;
  validatePreparationRetry(
    instance,
    retryPreparation: options.retryPreparation,
    initialMoment: initialMoment,
    services: services0,
    journey: readJourneyState(p.join(directory, '.journey.json')),
  );
  // Refuse occupied endpoints before starting an API; never mistake another service for ours.
  await _assertPortsFree([if (target.web && !backendOnly) webPort, bridgePort]);
  if (instance?['phase'] == 'seeding' && instance?['launch'] == null) {
    throw const MomentsError('Previous base preparation was interrupted. Reset this local instance before rebuilding.');
  }
  final interrupted = readJourneyState(p.join(directory, '.journey.json'));
  if (interrupted != null && (instance?['launch'] == null || instance?['phase'] != 'ready')) {
    throw const MomentsError('Interrupted journey has no committed base; inspect its preparation before starting');
  }
  final openingName = (interrupted?['name'] as String?) ?? initialMoment;
  void preflightSavedOpening() {
    final contract = readManifest(adapter.manifestFile);
    assertMaterializable(((contract['moments']! as Map)[openingName] as Map?)?.cast());
    validateSavedOpening(
      contract,
      p.join(directory, 'ui-session.json'),
      openingName,
      fresh: interrupted != null ? false : options.fresh,
    );
  }

  // Fail an already incompatible draft before owning/starting infrastructure,
  // then check again at the recipe boundary after asynchronous startup work.
  preflightSavedOpening();
  if (interrupted != null && options.fresh) {
    throw const MomentsError('An interrupted journey must be inspected and recovered before preparing fresh data');
  }
  final declaredBackend =
      (((readManifest(adapter.manifestFile)['moments']! as Map)[openingName] as Map?)?['backend'] as Map?)
          ?.cast<String, Object?>();
  final resuming =
      interrupted == null &&
      !options.fresh &&
      !options.retryPreparation &&
      preparedRecipeMatches(instance, openingName, declaredBackend);
  if (instance?['launch'] != null &&
      instance?['phase'] == 'ready' &&
      interrupted == null &&
      !resuming &&
      !options.fresh &&
      !options.retryPreparation) {
    throw MomentsError(
      'Stored preparation does not identify $openingName; inspect its data, then use moments up $openingName --fresh for an explicit new preparation',
    );
  }
  final lifecycle = await withInstanceLock(directory, () async {
    assertNoManagedSession(directory);
    final latest = File(manifest).existsSync() ? _read(manifest) : null;
    if (!jsonEqual(latest, instance)) throw const MomentsError('Instance changed during startup; run up again');
    return Lifecycle.create(
      project: project,
      directory: directory,
      instanceId: instance?['id'] as String?,
      android: target.android
          ? {
              'device': target.id,
              'ports': {apiPort, bridgePort}.toList(),
            }
          : null,
      ports: {apiPort, bridgePort, if (target.web) webPort, for (final s in services0) s.port}.toList(),
    );
  });
  var current = instance;
  Process? flutter;
  Bridge? bridge;
  FlutterMachine? machine;
  MomentWatcher? watcher;
  RenewalCoordinator? renewal;
  AndroidTransport? android;
  _BackendWatch? backendWatch;
  Future<void>? stopping;
  void persist(Map<String, Object?> next) {
    savePrivateState(manifest, next);
    current = next;
  }

  void checkpointPreparation(String stage) {
    final preparation = current?['preparation'] as Map?;
    if (preparation != null)
      persist({
        ...current!,
        'preparation': {...preparation, 'stage': stage},
      });
  }

  final services = Services(
    definitions: services0,
    directory: directory,
    lifecycle: lifecycle,
    prepareOnStart: interrupted == null && !resuming,
  );
  Future<void> assertAvailable() async {
    if (stopping != null || (assertOwned(current!)['State'] as Map?)?['Running'] != true) {
      throw const MomentsError('Owned backend is not running');
    }
  }

  final backendRecipes = BackendRecipes(
    manifestFile: adapter.manifestFile,
    recipes: adapter.recipes(),
    instance: () => current!,
    assertAvailable: assertAvailable,
    startBase: (baseRecipe) async {
      checkpointPreparation('base');
      persist({...current!, 'baseRecipe': baseRecipe, 'phase': 'seeding'});
    },
    commit: (launch, {base, preparedMoment}) async {
      persist({
        ...current!,
        'launch': launch,
        if (base != null) ...{'baseRecipe': base, 'phase': 'ready', 'preparedMoment': null},
        'preparedMoment': ?preparedMoment,
      });
    },
    beforePrepare: (_) async {
      // Once a new preparation starts, the old launch must not be claimed as
      // its completed result if an adapter fails or the process disappears.
      persist({...current!, 'preparedMoment': null});
      checkpointPreparation('services');
      await services.ensure();
      checkpointPreparation('recipe');
    },
    acquire: () => watcher?.pause() ?? () {},
  );
  Future<void> stopChild(Process? child) async {
    if (child == null) return;
    child.kill(ProcessSignal.sigterm);
    await child.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        child.kill(ProcessSignal.sigkill);
        return child.exitCode;
      },
    );
  }

  Future<void> stop() => stopping ??= () async {
    renewal?.close();
    watcher?.close();
    machine?.close();
    backendWatch?.close();
    final resources = lifecycle.freeze();
    await stopChild(flutter);
    await bridge?.close();
    await services.close();
    if (android != null &&
        File(p.join(directory, 'android-${lifecycle.state['runId']}', 'transport.json')).existsSync()) {
      await android.close();
    }
    await stopOwnedResources(resources, instance: current, directory: directory);
    lifecycle.finish();
  }();

  // Coalesce repeated interrupts until asynchronous resource cleanup completes.
  final signals = [
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) signal.watch().listen((_) => unawaited(stop())),
  ];
  Future<void> waitReady(
    Future<bool> Function() probe, {
    Process? child,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    var exited = false;
    unawaited(child?.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (stopping != null) throw const MomentsError('Moment startup interrupted');
      if (exited) throw const MomentsError('Local process exited during startup');
      try {
        if (await probe()) return;
      } on Object {
        // Not ready yet.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw const MomentsError('Local service readiness timed out');
  }

  try {
    await services.preflight();
    if (target.android) {
      android = AndroidTransport(
        directory: p.join(directory, 'android-${lifecycle.state['runId']}'),
        device: target.id,
        ports: ((lifecycle.state['android']! as Map)['ports']! as List).cast<int>(),
        owner: lifecycle.state['runId']! as String,
      );
      await android.start();
    }
    if (!backendRecipes.declared(openingName)) throw const MomentsError('This sandbox needs a declared backend recipe');
    if (current == null) {
      final id = lifecycle.state['instanceId']! as String;
      persist({
        'id': id,
        'container': 'moments-$id',
        'workspace': lifecycle.state['workspace'],
        'databasePhase': 'creating',
        'password': '${_hex(24)}Aa1!',
        'jwtSecret': _hex(32),
        'apiUrl': 'http://127.0.0.1:$apiPort',
        'webUrl': 'http://127.0.0.1:$webPort',
        'name': name,
      });
    }
    if (current!['workspace'] != null && current!['workspace'] != lifecycle.state['workspace']) {
      throw const MomentsError('Database belongs to another workspace');
    }
    lifecycle.claimDatabase();
    final existing = findOwnedDatabase(current!, allowAbsent: current!['databasePhase'] == 'creating');
    if (existing == null) {
      databaseDocker([
        'run',
        '-d',
        '--name',
        current!['container']! as String,
        '--label',
        '$_label=${current!['id']}',
        '--label',
        'dev.moments.workspace=${current!['workspace']}',
        '--label',
        'dev.moments.role=database',
        '-p',
        '127.0.0.1::5432',
        '-e',
        'POSTGRES_PASSWORD=${current!['password']}',
        '-e',
        'POSTGRES_DB=$database',
        adapter.databaseImage,
      ]);
    } else {
      databaseDocker(['start', existing['Id']! as String]);
    }
    final ports = ((assertOwned(current!)['NetworkSettings']! as Map)['Ports']! as Map)['5432/tcp'] as List;
    persist({...current!, 'pgPort': int.parse((ports.first as Map)['HostPort'] as String)});
    stdout.writeln('Moments: isolated database ${current!['container']}');
    await waitReady(() async {
      databaseDocker([
        'exec',
        current!['container']! as String,
        'pg_isready',
        '-h',
        '127.0.0.1',
        '-U',
        'postgres',
        '-d',
        database,
      ]);
      return true;
    });
    // pg_isready reports server readiness even when the requested database is
    // absent (for example, interrupted image initialization). Do not mark that
    // as a ready application database or start migrations against it.
    try {
      databaseDocker([
        'exec',
        current!['container']! as String,
        'psql',
        '-X',
        '-qAt',
        '-v',
        'ON_ERROR_STOP=1',
        '-U',
        'postgres',
        '-d',
        database,
        '-c',
        'SELECT 1',
      ]);
    } on Object {
      throw const MomentsError(
        'Owned PostgreSQL is running but the declared database is unavailable; inspect initialization before resuming or explicitly resetting this disposable instance',
      );
    }
    persist({...current!, 'databasePhase': 'ready'});
    if (interrupted == null && !resuming) {
      persist({
        ...current!,
        'preparation': {
          'moment': openingName,
          'stage': 'startup',
          'startedAt': DateTime.now().toUtc().toIso8601String(),
        },
      });
    }
    Directory(p.join(directory, 'tmp')).createSync(recursive: true);
    if (stopping != null) throw const MomentsError('Moment startup interrupted');
    if (interrupted != null || resuming) {
      await services.ensure();
      stdout.writeln(
        interrupted != null
            ? 'Moments: interrupted journey ${interrupted['name']}; opening for inspection without preparation. Inspect effects, then use moments recover.'
            : 'Moments: resuming $openingName; private launch and data preserved, preparation skipped.',
      );
    } else {
      preflightSavedOpening();
      await backendRecipes.prepare(openingName);
      await backendRecipes.inspect(openingName);
      persist({...current!, 'preparation': null});
    }
    if (current!['launch'] == null) throw const MomentsError('Declared backend base did not provide a launch');
    if (interrupted == null)
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(await backendRecipes.inspect(openingName)));
    final resolve = adapter.resolveInput;
    bridge = await Bridge.start(
      project: project,
      sessionDirectory: directory,
      port: bridgePort,
      momentsOptions: MomentsOptions(
        directory: p.join(project, 'moments'),
        sessionFile: p.join(directory, 'ui-session.json'),
        initialName: name,
        openName: openingName,
        fresh: interrupted != null ? false : options.fresh,
        manifestFile: adapter.manifestFile,
        prepare: backendRecipes.prepare,
        afterPreparedOpen: adapter.restartOnOpen
            ? (_) async {
                final active = watcher;
                if (active == null) throw const MomentsError('Flutter supervisor is not ready');
                final result = await active.refresh(restart: true);
                if (result['phase'] != 'ready')
                  throw MomentsError('${result['error'] ?? 'Prepared launch was not restored'}');
              }
            : null,
      ),
      bootstrap: () => {...(current!['launch']! as Map).cast<String, Object?>(), 'apiUrl': current!['apiUrl']},
      resolveInput: resolve == null ? null : (reference) => resolve(current!, reference),
      development: _Development(
        renewal: adapter.renewable == null ? null : _LateRenewal(() => renewal, adapter.renewable!),
        statusFn: () {
          final state = backendOnly
              ? backendWatch?.status() ?? {'phase': 'starting'}
              : watcher?.status() ?? {'phase': 'starting'};
          final serviceStates = services.status();
          final failed = serviceStates.where((s) => s['phase'] == 'error').firstOrNull;
          return {
            ...state,
            if (!backendOnly) 'target': {'requested': target.device, 'connected': machine?.device()},
            'services': serviceStates,
            if (failed != null && !const ['compiling', 'restoring'].contains(state['phase'])) ...{
              'phase': 'error',
              'error': failed['error'],
              'failureStage': 'backend',
            },
          };
        },
        stop: stop,
        inspect: () async {
          await assertAvailable();
          final context = bridge!.moments!.inspect();
          final selected = (context['state'] as Map?)?['name'] as String?;
          if (backendRecipes.declared(selected)) {
            return backendRecipes.inspect(
              selected!,
              context: {'projection': (context['observed'] as Map?)?['projection']},
            );
          }
          return {'status': 'not-configured'};
        },
        refresh: (input) {
          final restart = input['restart'] ?? false;
          if (restart is! bool) throw const MomentsError('restart must be a boolean');
          final active = watcher;
          if (active == null || !machine!.ready()) throw const MomentsError('Flutter is not ready');
          final status = active.status();
          if (status['held'] == true || const ['compiling', 'restoring'].contains(status['phase'])) {
            throw const MomentsError('A refresh is already running');
          }
          unawaited(active.refresh(restart: restart));
          return active.status();
        },
      ),
    );
    if (backendOnly) {
      backendWatch = _BackendWatch(services, () => bridge!.journeyStatus()['phase'] == 'idle');
      stdout.writeln(
        'Moments: backend only (no Flutter runtime). Run moments suite to check Moments; backend edits apply automatically between journeys.',
      );
      while (stopping == null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return;
    }
    final defines = _read(bridge.definesFile);
    savePrivateState(bridge.definesFile, {
      ...defines,
      'MANA_API_URL': current!['apiUrl'],
      'MANA_MOMENT_BOOTSTRAP': 'true',
      ...adapter.flutterDefines(current!),
    });
    final route = (current!['launch']! as Map)['route'];
    stdout.writeln(target.web ? 'Open ${current!['webUrl']}$route' : 'Open native ${target.device}: $route');
    stdout.writeln('Ctrl+C stops this instance; database and uploads remain for the next up.');
    final flutterTmp = flutterTemporaryDirectory(directory, lifecycle.state['runId']! as String);
    Directory(flutterTmp).createSync(recursive: true);
    flutter = await Process.start(
      'flutter',
      [
        'run',
        if (adapter.entrypoint != null) ...['-t', adapter.entrypoint!],
        '--machine',
        ...target.args,
        '--dart-define-from-file=${bridge.definesFile}',
      ],
      workingDirectory: project,
      environment: {'TMPDIR': flutterTmp},
    );
    unawaited(flutter.stderr.forEach(stderr.add));
    lifecycle.track(flutter, 'flutter');
    machine = FlutterMachine(flutter, onStarted: lifecycle.scan);
    watcher = MomentWatcher(
      project: project,
      paths: bridge.moments!.watchPaths,
      moments: bridge.moments!,
      machine: machine,
      enabled: options.watch,
      eventRoots: bridge.moments!.sourceLibraries,
      backend: services,
      automaticAllowed: () => bridge!.journeyStatus()['phase'] == 'idle',
    );
    if (adapter.renewable != null) {
      renewal = RenewalCoordinator(
        acquire: (target) {
          if (stopping != null) throw const MomentsError('This launcher cannot renew its recipe');
          bridge!.moments!.validateName(target);
          if (!adapter.renewable!.contains(target)) throw const MomentsError('This moment has no renewal recipe');
          if ((assertOwned(current!)['State'] as Map?)?['Running'] != true) {
            throw const MomentsError('Owned backend is not running');
          }
          return watcher!.pause();
        },
        prepare: (_, signal) => adapter.renew(current!, signal),
        commit: (launch) => persist({...current!, 'launch': launch}),
        refresh: (target) async {
          bridge!.moments!.open(target, fresh: true);
          return watcher!.refresh(restart: true);
        },
      );
    }
    stdout.writeln(
      'Moments: automatic refresh ${options.watch ? 'enabled' : 'disabled'} for ${bridge.moments!.watchPaths.length} declared files plus resolved local Dart libraries. Use moment refresh for a manual update, or refresh --restart for initialization changes.',
    );
    if (options.openBrowser && target.web) {
      final webUrl = current!['webUrl']! as String;
      await waitReady(
        () async {
          final client = HttpClient();
          try {
            final response = await (await client.getUrl(Uri.parse(webUrl))).close().timeout(const Duration(seconds: 1));
            await response.drain<void>();
            return response.statusCode < 400;
          } finally {
            client.close(force: true);
          }
        },
        child: flutter,
        timeout: const Duration(seconds: 120),
      );
      try {
        await Process.start('xdg-open', ['$webUrl$route'], mode: ProcessStartMode.detached);
      } on ProcessException {
        stderr.writeln('Open $webUrl$route');
      }
    }
    final code = await flutter.exitCode;
    if (code != 0 && stopping == null) exitCode = code;
  } finally {
    await stop();
    for (final subscription in signals) {
      await subscription.cancel();
    }
  }
}
