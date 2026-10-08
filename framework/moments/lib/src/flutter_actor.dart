import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show recoverOwnedContainer, savePrivateState;
import 'package:path/path.dart' as p;

import 'android_actor.dart';
import 'bridge.dart';
import 'browser.dart';
import 'check.dart';
import 'errors.dart';
import 'flutter_machine.dart';
import 'flutter_target.dart';
import 'inspect.dart';
import 'json.dart';
import 'layers.dart';
import 'materializer.dart';
import 'owned_process.dart';
import 'private_fs.dart';
import 'runtime.dart';
import 'suite.dart' show selfCommand;

/// Hidden subcommand that serves a compiled web artifact for one actor.
const webActorWorker = '__web-actor';

/// The consumer's backend for actors: allocation is synchronous ownership,
/// `start` launches against the actor's database copy.
abstract interface class ActorBackend {
  Map<String, Object?> allocate({required String dir});
  Future<void> start(
    Map<String, Object?> handle, {
    required String database,
    required LayerHandle databaseHandle,
    required String databaseDirectory,
    required String webOrigin,
  });
  Future<void> stop(Map<String, Object?> handle);
}

/// How the app reaches an actor's runtime.
final class ActorFrontend {
  const ActorFrontend.flutterRun({required this.cwd})
    : mode = 'flutter-run',
      artifact = null,
      device = null,
      applicationId = null,
      runtimeBootstrap = false,
      applicationBinary = null;

  const ActorFrontend.sharedDebugArtifact({required this.cwd, required String this.artifact})
    : mode = 'shared-debug-artifact',
      device = null,
      applicationId = null,
      runtimeBootstrap = false,
      applicationBinary = null;

  const ActorFrontend.android({
    required this.cwd,
    required String this.device,
    required String this.applicationId,
    this.runtimeBootstrap = false,
    this.applicationBinary,
  }) : mode = 'flutter-android',
       artifact = null;

  final String mode, cwd;
  final String? artifact, device, applicationId, applicationBinary;
  final bool runtimeBootstrap;
}

/// What the bridge of one actor carries besides its Moments runtime.
final class ActorBridgeOptions {
  const ActorBridgeOptions({this.privateStores, this.bootstrap = const {}, this.resolveInput, this.development});
  final List<String>? privateStores;
  final Map<String, Object?> bootstrap;
  final String Function(String reference)? resolveInput;
  final Development? development;
}

/// The consumer's launch of one actor.
final class ActorLaunch {
  const ActorLaunch({required this.port, this.route = '/', this.validateBackend, this.bridgeOptions});
  final int port;
  final String route;
  final Future<void> Function(ActorHandle handle)? validateBackend;
  final FutureOr<ActorBridgeOptions> Function(ActorHandle handle)? bridgeOptions;
}

/// Everything one running actor owns.
final class ActorHandle {
  ActorHandle._(this.dir, this.world, this.target);
  final String dir;
  final World world;
  final FlutterTarget? target;
  var stopped = false;
  String? url;
  Map<String, Object?>? api, applicationBinary;
  Bridge? bridge;
  AndroidActor? android;
  OwnedProcess? flutter;
  Process? child;
  FlutterMachine? machine;
  IOSink? log;
  BrowserBoundary? browser;
  double? nativeStartupMs, webServerMs, actorStartupMs, browserReadyMs, nativeReadyMs;
  var _spawnFailed = false, _served = false, _exited = false;
}

/// [Process] whose standard output is shared between a log and a reader.
final class _Teed implements Process {
  _Teed(this._inner, this.stdout);
  final Process _inner;
  @override
  final Stream<List<int>> stdout;
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => _inner.stdin;
  @override
  int get pid => _inner.pid;
  @override
  Future<int> get exitCode => _inner.exitCode;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => _inner.kill(signal);
}

double _ms(Stopwatch watch) => watch.elapsedMicroseconds / 1000;

/// Services for a materialized Flutter actor. The consumer supplies the
/// backend and domain-specific bridge observations. The host still owns
/// browser launch and closure; a stopped web server is not evidence that its
/// tab is closed.
final class FlutterActorServices {
  FlutterActorServices({
    required this.project,
    required this.manifestFile,
    required this.backend,
    required this.frontend,
    this.assertBrowserClosed,
    this.worker,
  }) {
    final native = frontend.mode == 'flutter-android';
    if (frontend.applicationBinary != null && !frontend.runtimeBootstrap) {
      throw const MomentsError('A prebuilt Android actor requires runtime bootstrap and an explicit APK path');
    }
    if (!native && assertBrowserClosed == null) {
      throw const MomentsError('Actor services require backend, frontend and explicit browser closure adapters');
    }
    _binary = frontend.applicationBinary == null
        ? null
        : AndroidBinary(file: frontend.applicationBinary!, applicationId: frontend.applicationId!);
    _target = native ? flutterTarget(frontend.device!) : null;
    if (native && !_target!.android) {
      throw const MomentsError('Native actors require an explicit Android device and application ID');
    }
  }

  final String project, manifestFile;
  final ActorBackend backend;
  final ActorFrontend frontend;
  final FutureOr<void> Function(ActorHandle handle)? assertBrowserClosed;

  /// The program hosting the owned-process and web actor workers; this
  /// program by default.
  final List<String>? worker;
  late final AndroidBinary? _binary;
  late final FlutterTarget? _target;
  final _owned = Expando<({List<String> phase, List<Future<void>?> start, List<Future<void>?> stop})>();

  bool get native => frontend.mode == 'flutter-android';

  ({List<String> phase, List<Future<void>?> start, List<Future<void>?> stop}) _state(ActorHandle handle) =>
      _owned[handle] ?? (throw const MomentsError('Actor belongs to another service runtime'));

  ActorHandle allocate(World world) {
    final actor = world.handles['actor']?['dir'], database = world.handles['db']?['database'];
    if (actor is! String || database is! String) {
      throw const MomentsError('Actor services require owned actor and database layers');
    }
    final handle = ActorHandle._(actor, world, _target);
    _owned[handle] = (phase: ['allocated'], start: [null], stop: [null]);
    return handle;
  }

  Future<ActorHandle> start(ActorHandle handle, ActorLaunch launch) async {
    final lifecycle = _state(handle);
    if (lifecycle.phase[0] != 'allocated') throw const MomentsError('Actor service startup cannot be replayed');
    if (launch.port < 1 || launch.port > 65535 || !launch.route.startsWith('/') || launch.route.startsWith('//')) {
      throw const MomentsError('Invalid actor service launch');
    }
    final origin = 'http://127.0.0.1:${launch.port}';
    final url = Uri.parse(origin).resolve(launch.route);
    // Browsers read `\` as `/`, so `/\host` would leave the loopback origin.
    if ('${url.scheme}://${url.host}:${url.port}' != origin || url.userInfo.isNotEmpty || launch.route.contains('\\')) {
      throw const MomentsError('Actor route must retain its loopback origin');
    }
    lifecycle.phase[0] = 'starting';
    final start = lifecycle.start[0] = () async {
      final started = Stopwatch()..start();
      final world = handle.world;
      handle.url = href(url);
      // Pin the caller-owned build on its first use. Never silently switch
      // binaries between branches in this runtime.
      if (_binary != null) handle.applicationBinary = _binary.read();
      // Store each ownership handle before starting the associated service.
      final api = handle.api = backend.allocate(dir: world.dir);
      await backend.start(
        api,
        database: world.handles['db']!['database']! as String,
        databaseHandle: world.handles['db']!,
        databaseDirectory: p.join(world.dir, 'db'),
        webOrigin: origin,
      );
      await launch.validateBackend?.call(handle);
      final options = await launch.bridgeOptions?.call(handle) ?? const ActorBridgeOptions();
      final apiUrl = api['url']! as String;
      final bridge = handle.bridge = await Bridge.start(
        directory: p.join(project, 'live-ui'),
        sessionDirectory: handle.dir,
        port: 0,
        momentsOptions: MomentsOptions(
          directory: p.join(project, 'moments'),
          sessionFile: p.join(handle.dir, 'ui-session.json'),
          manifestFile: manifestFile,
          materialization: world.materialization,
        ),
        privateStores: options.privateStores,
        resolveInput: options.resolveInput,
        development: native && options.development != null
            ? _NativeDevelopment(options.development!, _target!, () => handle.machine?.device())
            : options.development,
        bootstrap: () => {...options.bootstrap, 'apiUrl': apiUrl, 'privateStore': true},
      );
      if (native) {
        final parsed = Uri.parse(apiUrl);
        if (parsed.scheme != 'http' || parsed.host != '127.0.0.1' || parsed.userInfo.isNotEmpty || !parsed.hasPort) {
          throw const MomentsError('Native actor transport requires a loopback HTTP API');
        }
        handle.android = AndroidActor(
          directory: world.dir,
          device: _target!.id,
          applicationId: frontend.applicationId!,
          owner: world.id,
          ports: {parsed.port, Uri.parse(bridge.url).port}.toList(),
        );
        await handle.android!.prepare();
      }
      savePrivateState(
        bridge.definesFile,
        frontend.runtimeBootstrap
            ? {'MANA_MOMENTS': 'true', 'MANA_MOMENT_BOOTSTRAP': 'true', 'MANA_RUNTIME_BOOTSTRAP': 'true'}
            : {
                ...(jsonDecode(File(bridge.definesFile).readAsStringSync()) as Map).cast<String, Object?>(),
                'MANA_API_URL': apiUrl,
                'MANA_MOMENT_BOOTSTRAP': 'true',
              },
      );
      final logFile = p.join(world.dir, 'flutter.log');
      createExclusive(logFile, const []);
      final log = handle.log = File(logFile).openWrite(mode: FileMode.append);
      handle.flutter = allocateOwnedProcess(world.dir, worker: worker);
      final web = Stopwatch()..start();
      final configuration = p.join(world.dir, 'web-config.json');
      final artifact = frontend.artifact == null ? null : p.normalize(p.absolute(frontend.artifact!));
      if (artifact != null) {
        savePrivateState(configuration, {
          'artifact': artifact,
          'port': launch.port,
          'apiUrl': apiUrl,
          'bridgeUrl': bridge.url,
          'bridgeToken': bridge.token,
        });
      }
      final binary = _binary;
      final command = native
          ? [
              'flutter',
              'run',
              '--machine',
              ..._target!.args,
              if (binary != null) ...[
                '--no-hot',
                '--no-pub',
                '--use-application-binary=${binary.file}',
              ] else
                '--dart-define-from-file=${bridge.definesFile}',
              if (frontend.runtimeBootstrap) ...[
                '--route',
                nativeMomentRoute(apiUrl: apiUrl, bridgeUrl: bridge.url, bridgeToken: bridge.token),
              ],
            ]
          : artifact != null
          ? [...(worker ?? selfCommand()), webActorWorker, configuration]
          : [
              'flutter',
              'run',
              '-d',
              'web-server',
              '--web-hostname=127.0.0.1',
              '--web-port=${launch.port}',
              '--dart-define-from-file=${bridge.definesFile}',
            ];
      await handle.flutter!.start(
        command: command,
        cwd: p.normalize(p.absolute(frontend.cwd)),
        onSpawn: (child) {
          handle.child = child;
          final out = child.stdout.asBroadcastStream();
          void record(List<int> bytes) {
            log.add(bytes);
            if (!handle._served && utf8.decode(bytes, allowMalformed: true).contains('is being served at')) {
              handle._served = true;
            }
          }

          out.listen(record, onError: (_) {});
          child.stderr.listen(record, onError: (_) {});
          unawaited(child.exitCode.then((_) => handle._exited = true));
          if (native) handle.machine = FlutterMachine(_Teed(child, out), log: (_) {});
        },
      );
      final deadline = DateTime.now().add(Duration(seconds: native ? 180 : 60));
      while (true) {
        if (handle._spawnFailed || handle._exited) {
          throw const MomentsError('Flutter actor exited during startup; inspect its private log');
        }
        if (native ? handle.machine!.ready() : handle._served) break;
        if (DateTime.now().isAfter(deadline)) throw const MomentsError('Flutter actor readiness timed out');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (native) {
        if (handle.machine!.device() != _target!.id)
          throw const MomentsError('Flutter connected to another Android device');
        await handle.android!.confirmStarted();
        handle.nativeStartupMs = _ms(web);
        handle.url = 'android://${_target.id}/${frontend.applicationId}';
        savePrivateState(p.join(world.dir, 'native-launch.json'), {
          'version': 1,
          'device': _target.id,
          'mode': binary != null ? 'prebuilt-debug' : 'flutter-run',
          'artifact': handle.applicationBinary,
          'startupMs': handle.nativeStartupMs,
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          'scope': 'Flutter app.started and owned Android package confirmed; journey criteria are separate',
        });
      } else {
        handle.webServerMs = _ms(web);
      }
      handle.actorStartupMs = _ms(started);
      lifecycle.phase[0] = 'ready';
    }();
    try {
      await start;
      return handle;
    } on Object {
      lifecycle.phase[0] = 'attention';
      rethrow;
    }
  }

  Future<void> stop(ActorHandle handle) {
    final lifecycle = _state(handle);
    if (lifecycle.stop[0] case final running?) return running;
    if (lifecycle.phase[0] == 'stopped') return Future.value();
    lifecycle.phase[0] = 'stopping';
    final stop = lifecycle.stop[0] = () async {
      try {
        // Never race cleanup against a service that can still be allocated.
        await lifecycle.start[0]?.catchError((_) {});
        if (!native) await assertBrowserClosed!(handle);
        await handle.flutter?.stop();
        handle.machine?.close();
        await handle.android?.close();
        await handle.bridge?.close();
        if (handle.api case final api?) await backend.stop(api);
        await handle.log?.close();
        handle.stopped = true;
        lifecycle.phase[0] = 'stopped';
      } finally {
        lifecycle.stop[0] = null;
      }
    }();
    return stop;
  }
}

final class _NativeDevelopment implements Development {
  _NativeDevelopment(this._inner, this._target, this._connected);
  final Development _inner;
  final FlutterTarget _target;
  final String? Function() _connected;
  @override
  Map<String, Object?> status() => {
    ..._inner.status(),
    'target': {'requested': _target.device, 'connected': _connected()},
  };
  @override
  Future<Map<String, Object?>> Function()? get inspect => _inner.inspect;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => _inner.refresh;
  @override
  Future<void> Function()? get stop => _inner.stop;
  @override
  Renewal? get renewal => _inner.renewal;
}

/// The standard services with a host-owned browser and the same Moment
/// journey executor the CLI uses. Consumer callbacks configure the backend,
/// observations and private inputs; they never operate tabs or acknowledge UI.
final class FlutterActorRuntime implements MaterializerRuntime {
  FlutterActorRuntime({
    required this.project,
    required this.manifestFile,
    required ActorBackend backend,
    required ActorFrontend frontend,
    this.browserProvider,
    required this.configure,
    List<String>? worker,
  }) : _native = frontend.mode == 'flutter-android' {
    if (!_native &&
        (browserProvider == null ||
            browserProvider!.open == null ||
            browserProvider!.resolve == null ||
            browserProvider!.inspect == null ||
            browserProvider!.close == null)) {
      throw const MomentsError('Managed Flutter actors require configuration and a complete browser host');
    }
    if (_native && browserProvider != null) throw const MomentsError('Android actors do not use a browser provider');
    _services = FlutterActorServices(
      project: project,
      manifestFile: manifestFile,
      backend: backend,
      frontend: frontend,
      assertBrowserClosed: (handle) => handle.browser!.assertClosed(),
      worker: worker,
    );
  }

  final String project, manifestFile;
  final BrowserProvider? browserProvider;
  final FutureOr<ActorLaunch> Function(ActorHandle handle) configure;
  final bool _native;
  late final FlutterActorServices _services;
  final _phases = Expando<List<Object?>>();
  final _byDirectory = <String, ActorHandle>{};

  List<Object?> _owned(Object handle) =>
      (handle is ActorHandle ? _phases[handle] : null) ??
      (throw const MomentsError('Actor belongs to another runtime'));

  @override
  String get type => _native ? 'ash-flutter-android' : 'ash-flutter-local';

  @override
  ActorHandle allocate(World world) {
    final handle = _services.allocate(world);
    _phases[handle] = ['allocated', null, null];
    _byDirectory[handle.dir] = handle;
    if (!_native) handle.browser = allocateBrowserBoundary(world.dir);
    return handle;
  }

  @override
  Future<void> start(Object raw, World world) async {
    final state = _owned(raw), handle = raw as ActorHandle;
    if (world != handle.world) throw const MomentsError('Actor world identity changed');
    if (state[0] != 'allocated') throw const MomentsError('Actor runtime startup cannot be replayed');
    state[0] = 'starting';
    final start = () async {
      await _services.start(handle, await configure(handle));
      final started = Stopwatch()..start();
      if (!_native) {
        await handle.browser!.open(handle.url!, browserProvider!);
        handle.url = handle.browser!.url;
      }
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        final inspected = handle.bridge!.moments!.inspect();
        final observed = inspected['observed'] as Map?;
        if (observed?['revision'] == inspected['revision'] &&
            observed?['client'] != null &&
            (inspected['state'] as Map?)?['name'] == world.name) {
          break;
        }
        if (DateTime.now().isAfter(deadline))
          throw const MomentsError('Owned Flutter actor did not report its restored Moment');
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_native) {
        handle.nativeReadyMs = _ms(started);
      } else {
        handle.browserReadyMs = _ms(started);
      }
      state[0] = 'ready';
    }();
    state[1] = start;
    try {
      await start;
    } on Object {
      state[0] = 'attention';
      rethrow;
    }
  }

  @override
  Future<Map<String, Object?>> Function(
    World world, {
    required String manifestFile,
    required String name,
    bool navigation,
    void Function()? assertCurrent,
  })
  get executeJourney => (world, {required manifestFile, required name, navigation = true, assertCurrent}) async {
    final handle = world.runtime;
    if (handle == null || _owned(handle)[0] != 'ready') throw const MomentsError('Actor runtime is not ready');
    handle as ActorHandle;
    if (manifestFile != this.manifestFile || name != handle.world.name) {
      throw const MomentsError('Journey does not belong to this actor');
    }
    final bridge = handle.bridge!;
    Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
      assertCurrent?.call();
      final client = HttpClient();
      try {
        final request = await client.openUrl(data == null ? 'GET' : 'POST', Uri.parse('${bridge.url}$path'));
        request.headers
          ..set('Authorization', 'Bearer ${bridge.token}')
          ..set('Content-Type', 'application/json');
        if (data != null) request.add(utf8.encode(jsonEncode(data)));
        final response = await request.close().timeout(const Duration(seconds: 15));
        final text = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300)
          throw const MomentsError('Owned bridge request failed');
        return asObject(jsonDecode(text));
      } finally {
        client.close(force: true);
      }
    }

    return checkMoment(
      project: project,
      name: name,
      manifestFile: manifestFile,
      request: request,
      navigation: navigation,
      materialized: true,
    );
  };

  @override
  Future<void> stop(Object raw) {
    final state = _owned(raw), handle = raw as ActorHandle;
    if (state[2] case final Future<void> running) return running;
    if (state[0] == 'stopped') return Future.value();
    state[0] = 'stopping';
    final stop = () async {
      try {
        await (state[1] as Future<void>?)?.catchError((_) {});
        if (!_native) await handle.browser!.close(browserProvider);
        await _services.stop(handle);
        state[0] = 'stopped';
      } finally {
        state[2] = null;
      }
    }();
    state[2] = stop;
    return stop;
  }

  /// The layer stop check: a copy whose actor is still live is never captured
  /// or disposed.
  void assertStopped(LayerHandle actor) {
    final handle = _byDirectory[actor['dir']];
    // No runtime has been allocated for this layer copy.
    if (handle == null) return;
    if (!handle.stopped) throw const MomentsError('Actor services remain live');
    if (_native) {
      handle.android?.assertStopped();
    } else {
      handle.browser!.assertClosed();
    }
  }
}

/// Stops the runtime of one materialized instance after its coordinator died.
abstract interface class RuntimeRecovery {
  String get type;
  Future<Map<String, Object?>> recover({required String dir, required String instanceId});
}

/// Runtime recovery for a dead coordinator. The bridge ran inside it; Flutter
/// and the API may outlive it. Browser closure is verified by the supplied
/// host provider before either service stops. No sources, recipes or
/// application credentials are loaded here.
final class LocalActorRecovery implements RuntimeRecovery {
  LocalActorRecovery({this.browserProvider, this.type = 'ash-flutter-local'}) {
    if (!const ['ash-flutter-local', 'ash-flutter-android'].contains(type)) {
      throw const MomentsError('Unsupported actor runtime recovery');
    }
  }
  final BrowserProvider? browserProvider;
  @override
  final String type;

  @override
  Future<Map<String, Object?>> recover({required String dir, required String instanceId}) async {
    if (type == 'ash-flutter-local' && exists(p.join(dir, 'transport.json'))) {
      throw const MomentsError('Android actor requires its explicit recovery adapter');
    }
    if (type == 'ash-flutter-android' && exists(p.join(dir, 'browser.json'))) {
      throw const MomentsError('Android actor has unexpected browser ownership');
    }
    if (exists(p.join(dir, 'browser.json'))) await recoverBrowserBoundary(dir).close(browserProvider);
    final process = exists(p.join(dir, 'process.json')) ? recoverOwnedProcess(dir) : null;
    final container = exists(p.join(dir, 'container.json')) ? recoverOwnedContainer(dir) : null;
    await process?.stop();
    if (type == 'ash-flutter-android' && exists(p.join(dir, 'transport.json'))) await recoverAndroidActor(dir);
    container?.stop();
    if ((process?.inspect().present ?? false) || (container?.inspect().present ?? false)) {
      throw const MomentsError('Actor runtime remains after recovery');
    }
    return {'status': 'stopped', 'instanceId': instanceId};
  }
}
