import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart'
    show
        Instance,
        identityJson,
        processIdentity,
        recoverOwnedContainer,
        savePrivateState,
        syncDirectory,
        uuidV4,
        validateDatabaseIdentity;
import 'package:path/path.dart' as p;

import 'browser.dart';
import 'check.dart';
import 'composition.dart';
import 'errors.dart';
import 'flutter_actor.dart';
import 'flutter_target.dart';
import 'journey.dart';
import 'json.dart';
import 'layers.dart';
import 'lifecycle.dart';
import 'manifest.dart';
import 'materializer.dart';
import 'owned_process.dart';
import 'postgres_layer.dart';
import 'private_fs.dart';

/// What `fork` and `open --isolated` hand the project's materialization adapter.
final class MaterializationContext {
  const MaterializationContext({
    required this.project,
    required this.manifestFile,
    required this.manifest,
    required this.directory,
    required this.name,
    required this.copies,
    this.browserProvider,
    this.device,
  });
  final String project, manifestFile, directory, name;
  final Manifest manifest;
  final int copies;
  final BrowserProvider? browserProvider;
  final String? device;
}

/// The layers, runtime and transitions a materialization runs on.
final class MaterializationEngine {
  const MaterializationEngine({
    required this.layers,
    required this.runtime,
    this.recipes = const {},
    required this.scope,
  });
  final List<Layer> layers;
  final MaterializerRuntime runtime;
  final Map<String, TransitionRecipe> recipes;
  final String scope;
}

/// Allocated synchronously, before any side effect: ownership and cleanup
/// exist before [prepare] creates resources.
abstract interface class MaterializationProfile {
  MaterializationEngine get engine;

  /// Local directories of `processes`/`containers` and named `roots` with
  /// their type, plus the cluster `instance` when a root is a database.
  Map<String, Object?> get recovery;
  String codeIdentity();
  Future<void> prepare({required Interruption signal, required void Function(Map<String, Object?> event) onProgress});
  Future<void> cleanup();
}

/// What `compose` hands the project's composition adapter.
final class CompositionContext {
  const CompositionContext({
    required this.project,
    required this.manifestFile,
    required this.manifest,
    required this.directory,
    required this.plan,
    required this.profile,
    required this.browserProvider,
  });
  final String project, manifestFile, directory, profile;
  final Manifest manifest;
  final Object? plan;
  final BrowserProvider browserProvider;
}

abstract interface class CompositionProfile {
  Map<String, Object?> get recovery;
  Future<void> prepare({required Interruption signal});
  Future<CompositionConnection> connect({required String surface, required String moment});
  Future<void> cleanup({required bool passed});
  Future<void> Function(String id)? get beforeStage;
  Future<void> Function(String id)? get afterStage;
  Future<Object?> Function()? get verify;
}

typedef PreparationAdapter =
    Future<Map<String, Object?>> Function({
      required String project,
      required String profile,
      required void Function(Map<String, Object?> event) onProgress,
    });

/// Trusted local code a project adds to Moments. A project registers it from
/// its own `moments/adapters.dart` program, which calls `runCli` with them;
/// the generic CLI delegates the commands that need it to that program.
final class ProjectAdapters {
  const ProjectAdapters({this.materialization, this.composition, this.preparation});
  final MaterializationProfile Function(MaterializationContext context)? materialization;
  final CompositionProfile Function(CompositionContext context)? composition;
  final PreparationAdapter? preparation;
}

final _segment = RegExp(r'^[a-z][a-z0-9-]{0,63}$');

Map<String, Object?> _read(String file, [int limit = 65536, String message = 'Invalid session recovery record']) =>
    readJsonObject(file, limit, message);

void _directory(String path) {
  if (realPath(path) != path || entityType(path) != FileSystemEntityType.directory) {
    throw const MomentsError('Session recovery refuses symbolic directories');
  }
}

bool _supervisorShape(Object? value) =>
    value is Map &&
    value['pid'] is int &&
    (value['pid']! as int) >= 1 &&
    RegExp(r'^\d+$').hasMatch('${value['start'] ?? ''}') &&
    isUuid(value['boot']);

Map<String, Object?> _supervisor() {
  final identity = processIdentity(pid);
  if (identity == null) throw const MomentsError('Cannot identify the session supervisor');
  return identityJson(identity);
}

/// The infrastructure a session may leave behind, validated before it exists.
Map<String, Object?> validateRecoveryResources(Object? value) {
  bool bounded(Object? list) => list is List && list.length <= 32;
  if (value is! Map || !bounded(value['processes']) || !bounded(value['containers']) || !bounded(value['roots'])) {
    throw const MomentsError('Declare bounded session recovery resources');
  }
  final browsers = value['browsers'];
  if (value.containsKey('browsers') && (browsers is! List || browsers.length > 8)) {
    throw const MomentsError('Declare bounded session browser resources');
  }
  final roots = (value['roots'] as List).map((r) => r is Map ? r : const {}).toList();
  final paths = [
    ...(value['processes'] as List),
    ...(value['containers'] as List),
    ...roots.map((r) => r['name']),
    ...?(browsers as List?),
  ];
  if (paths.any(
        (path) =>
            path is! String || !_segment.hasMatch(path) || const ['runs', 'initial', 'app', 'backend'].contains(path),
      ) ||
      paths.toSet().length != paths.length ||
      roots.any((r) => !const ['postgres', 'flutter-actor', 'private-json'].contains(r['type']))) {
    throw const MomentsError('Unsupported session recovery resources');
  }
  final instance = value['instance'] as Map?;
  if (roots.any((r) => r['type'] == 'postgres')) validateDatabaseIdentity((instance ?? const {}).cast());
  return {
    'processes': [...(value['processes'] as List)],
    'containers': [...(value['containers'] as List)],
    'roots': [
      for (final root in roots) {'name': root['name'], 'type': root['type']},
    ],
    if (browsers != null) 'browsers': [...browsers],
    if (instance != null) 'instance': {'id': instance['id'], 'container': instance['container']},
  };
}

final _drivers = <String, LayerDriver>{
  'postgres': PostgresLayer(),
  'flutter-actor': const FlutterActorLayer(),
  'private-json': const PrivateJsonLayer(),
};

/// Cleanup only: no manifest imports, source evaluation, recipes, restart or
/// replay. Adapters are supplied explicitly and must match the saved types.
Future<Map<String, Object?>> recoverMaterialization({
  required String directory,
  required List<Layer> layers,
  required RuntimeRecovery runtime,
  String? workspace,
}) async {
  final home = p.normalize(p.absolute(directory));
  _requireReal(home, 'Recovery refuses symbolic or foreign directories');
  return withInstanceLock(home, () async {
    final run = _read(p.join(home, 'run.json'), 1024 * 1024, 'Invalid materializer recovery record');
    if (run['version'] != 1 ||
        !isUuid(run['runId']) ||
        p.basename(home) != run['runId'] ||
        run['scope'] is! String ||
        (run['scope'] as String).isEmpty ||
        !sha256Pattern.hasMatch('${run['code'] ?? ''}') ||
        !sha256Pattern.hasMatch('${run['manifest'] ?? ''}') ||
        !_supervisorShape(run['supervisor'])) {
      throw const MomentsError('Invalid materializer run identity');
    }
    if (sameProcess((run['supervisor']! as Map).cast())) {
      throw const MomentsError('Materializer supervisor is still alive; stop it before recovery');
    }
    if (workspace != null && run['workspace'] != workspace) {
      throw const MomentsError('Materializer run belongs to a different or unregistered workspace');
    }
    final name = RegExp(r'^[a-z][a-z0-9-]*$');
    final saved = run['layers'];
    if (saved is! List ||
        saved.isEmpty ||
        saved.any((l) => l is! Map || !name.hasMatch('${l['name'] ?? ''}') || !name.hasMatch('${l['type'] ?? ''}')) ||
        saved.map((l) => (l as Map)['name']).toSet().length != saved.length ||
        layers.length != saved.length ||
        runtime.type != run['runtime']) {
      throw const MomentsError('Recovery adapters do not match the saved run');
    }
    final adapters = {for (final layer in layers) layer.name: layer};
    if (adapters.length != layers.length || saved.any((l) => adapters[(l as Map)['name']]?.driver.type != l['type'])) {
      throw const MomentsError('Recovery layer adapter missing or incompatible');
    }
    // Validate the complete inventory before stopping even the first resource.
    final declared = adapters.keys.toSet();
    final instances = _inventory(home, 'instances', run, declared),
        snapshots = _inventory(home, 'snapshots', run, declared);
    final recovered = <Map<String, Object?>>[], snapshotReceipts = <Map<String, Object?>>[];
    final result = <String, Object?>{
      'version': 1,
      'runId': run['runId'],
      'scope': run['scope'],
      'status': 'recovering',
      'recipeReplayed': false,
      'verification': 'not-performed',
      'recoveredBy': _supervisor(),
      'instances': recovered,
      'snapshots': snapshotReceipts,
    };
    final file = p.join(home, 'recovery.json');
    void save() => savePrivateState(file, result);
    save();
    try {
      // All runtimes stop before any data layer is touched.
      for (final instance in instances) {
        if (instance.empty) continue;
        final stopped = await runtime.recover(dir: instance.dir, instanceId: instance.id);
        if (stopped['status'] != 'stopped' || stopped['instanceId'] != instance.id) {
          throw const MomentsError('Runtime recovery did not confirm this instance stopped');
        }
        recovered.add({'id': instance.id, 'runtime': 'stopped', 'layers': <Object?>[]});
        save();
      }
      for (final (items, target) in [(instances, recovered), (snapshots, snapshotReceipts)]) {
        for (final item in items) {
          if (item.empty) continue;
          var receipt = target.where((v) => v['id'] == item.id).firstOrNull;
          if (receipt == null) {
            receipt = {'id': item.id, 'layers': <Object?>[]};
            target.add(receipt);
          }
          for (final declaration in saved.reversed.cast<Map>()) {
            final layer = item.layers.where((l) => l.name == declaration['name']).firstOrNull;
            if (layer == null) continue;
            final adapter = adapters[layer.name]!;
            final disposed = await adapter.driver.recover(dir: layer.dir, opts: adapter.opts, pending: layer.pending);
            if (disposed['status'] != 'disposed') throw const MomentsError('Layer recovery did not confirm disposal');
            (receipt['layers']! as List).add({'name': layer.name, 'status': 'disposed'});
            save();
          }
        }
      }
      result['status'] = 'disposed';
      save();
      return result;
    } on Object {
      result['status'] = 'attention';
      save();
      rethrow;
    }
  });
}

void _requireReal(String path, String message) {
  if (entityType(path) != FileSystemEntityType.directory || realPath(path) != path) throw MomentsError(message);
}

typedef _Item = ({String id, String dir, bool empty, List<({String name, String dir, bool pending})> layers});

List<_Item> _inventory(String home, String kind, Map<String, Object?> run, Set<String> declared) {
  final root = p.join(home, kind);
  if (!exists(root)) return const [];
  _requireReal(root, 'Recovery refuses symbolic or foreign directories');
  final entries = Directory(root).listSync();
  if (entries.length > 4096) throw const MomentsError('Recovery inventory exceeds limit');
  final name = RegExp(r'^[a-z][a-z0-9-]*$');
  return [
    for (final entry in entries)
      () {
        final id = p.basename(entry.path);
        if (!isUuid(id)) throw const MomentsError('Invalid materializer instance or snapshot name');
        final dir = p.join(root, id);
        _requireReal(dir, 'Recovery refuses symbolic or foreign directories');
        final file = p.join(dir, kind == 'instances' ? 'instance.json' : 'snapshot.json');
        if (!exists(file)) {
          if (Directory(dir).listSync().isNotEmpty)
            throw const MomentsError('Unrecorded materializer resources need inspection');
          return (id: id, dir: dir, empty: true, layers: <({String name, String dir, bool pending})>[]);
        }
        final record = _read(file, 1024 * 1024, 'Invalid materializer recovery record');
        if (record['id'] != id ||
            !name.hasMatch('${record['name'] ?? ''}') ||
            record['scope'] != run['scope'] ||
            record['code'] != run['code'] ||
            record['manifest'] != run['manifest']) {
          throw const MomentsError('Materializer inventory identity changed');
        }
        final layers = <({String name, String dir, bool pending})>[];
        if (kind == 'instances') {
          if (record['version'] != 1 ||
              record['layers'] is! Map ||
              !const [
                'materializing',
                'ready',
                'attention',
                'stopped',
                'disposing',
                'disposed',
                'transition-completed',
              ].contains(record['phase'])) {
            throw const MomentsError('Unsupported instance recovery record');
          }
          for (final MapEntry(:key, :value) in (record['layers']! as Map).entries) {
            if (!declared.contains(key) ||
                value is! Map ||
                value['dir'] != p.join(dir, key as String) ||
                !const ['materializing', 'ready', 'disposed'].contains(value['phase'])) {
              throw const MomentsError('Invalid instance layer reference');
            }
            layers.add((name: key, dir: value['dir']! as String, pending: value['phase'] != 'ready'));
          }
        } else {
          if (record['dir'] != dir ||
              record['layers'] is! Map ||
              record['pendingLayers'] is! Map ||
              !const ['capturing', 'ready', 'disposing', 'disposed'].contains(record['phase'])) {
            throw const MomentsError('Unsupported snapshot recovery record');
          }
          for (final (map, pending) in [(record['layers']! as Map, false), (record['pendingLayers']! as Map, true)]) {
            for (final MapEntry(:key, :value) in map.entries) {
              if (!declared.contains(key) || value != p.join(dir, key as String) || layers.any((l) => l.name == key)) {
                throw const MomentsError('Invalid snapshot layer reference');
              }
              layers.add((name: key, dir: value as String, pending: pending));
            }
          }
        }
        for (final layer in layers) {
          if (exists(layer.dir)) _requireReal(layer.dir, 'Recovery refuses symbolic or foreign directories');
        }
        // A direct subdirectory the coordinator did not inventory is not disposable.
        for (final child in Directory(dir).listSync(followLinks: false)) {
          if (entityType(child.path) != FileSystemEntityType.directory) continue;
          if (layers.any((l) => l.dir == child.path)) continue;
          final childName = p.basename(child.path);
          if (kind == 'snapshots' &&
              const ['disposing', 'disposed'].contains(record['phase']) &&
              declared.contains(childName)) {
            layers.add((name: childName, dir: child.path, pending: true));
          } else {
            throw const MomentsError('Unrecorded layer directory needs inspection');
          }
        }
        return (id: id, dir: dir, empty: false, layers: layers);
      }(),
  ];
}

/// Discards the copies of an interrupted run. Origin and external roots stay.
Future<Map<String, Object?>> recoverRun(
  String project, {
  required String directory,
  String? browserSocket,
  String? browserProvider,
}) async {
  final home = p.normalize(p.absolute(directory)), moments = p.join(realPath(project), 'moments');
  final relative = p.relative(home, from: moments);
  if (relative == '.' || relative.startsWith('..') || realPath(home) != home) {
    throw const MomentsError('Run must be a real directory inside this project’s moments directory');
  }
  Map<String, Object?> read(String file) => _read(file, 1024 * 1024, 'Invalid run recovery configuration');
  final run = read(p.join(home, 'run.json')), workspace = workspaceIdentity(project);
  if (run['workspace'] != workspace) {
    throw const MomentsError('Run has no matching workspace registration; use its original explicit adapters');
  }
  final saved = run['layers'];
  if (!const ['ash-flutter-local', 'ash-flutter-android'].contains(run['runtime']) ||
      saved is! List ||
      saved.any((l) => !_drivers.containsKey((l as Map)['type']))) {
    throw const MomentsError('Run profile is not supported by this recovery command');
  }
  Instance? instance;
  if (saved.any((l) => (l as Map)['type'] == 'postgres')) {
    final current = read(p.join(moments, '.backend/instance.json'));
    if (current.containsKey('workspace') && current['workspace'] != workspace) {
      throw const MomentsError('Database instance belongs to a different workspace');
    }
    instance = {'id': current['id'], 'container': current['container']};
  }
  final provider = browserSocket != null ? browserSocketProvider(path: browserSocket, id: browserProvider!) : null;
  final actorOpts = LayerOptions(
    assertStopped: (handle) {
      final dir = p.dirname(handle['dir']! as String);
      if (exists(p.join(dir, 'browser.json'))) recoverBrowserBoundary(dir).assertClosed();
      if (exists(p.join(dir, 'process.json')) && recoverOwnedProcess(dir).inspect().present) {
        throw const MomentsError('Actor process still exists');
      }
      if (exists(p.join(dir, 'container.json')) && recoverOwnedContainer(dir).inspect().present) {
        throw const MomentsError('Actor container still exists');
      }
      if (exists(p.join(dir, 'transport.json')) && read(p.join(dir, 'transport.json'))['phase'] != 'disposed') {
        throw const MomentsError('Android transport still exists');
      }
      if (exists(p.join(dir, 'android-app.json')) && read(p.join(dir, 'android-app.json'))['phase'] != 'stopped') {
        throw const MomentsError('Android app closure unconfirmed');
      }
    },
  );
  final layers = [
    for (final layer in saved.cast<Map>())
      (
        name: layer['name']! as String,
        driver: _drivers[layer['type']]!,
        root: '',
        opts: layer['type'] == 'postgres' ? LayerOptions(instance: instance) : actorOpts,
      ),
  ];
  return recoverMaterialization(
    directory: home,
    workspace: workspace,
    layers: layers,
    runtime: LocalActorRecovery(browserProvider: provider, type: run['runtime']! as String),
  );
}

String _session(String project, String directory, String message) {
  final home = p.normalize(p.absolute(directory));
  if (!isUuid(p.basename(home)) || home != p.join(project, 'moments/.proofs/materializations', p.basename(home))) {
    throw MomentsError(message);
  }
  return home;
}

/// A materialized session: one supervisor, its run and its open actors.
final class ManagedSession {
  ManagedSession._(this.ready, this.close);
  final Map<String, Object?> ready;
  final Future<void> Function() close;
}

Future<ManagedSession> openManagedSession({
  required String project,
  required String name,
  required ProjectAdapters adapters,
  int copies = 1,
  String? browserSocket,
  String? browserProvider,
  String? device,
  Interruption? signal,
  void Function(Map<String, Object?> event)? onProgress,
}) async {
  project = realPath(project);
  if (copies < 1 || copies > 8) throw const MomentsError('Choose 1–8 actor copies');
  final native = device != null;
  if (native && (!flutterTarget(device).android || copies != 1 || browserSocket != null || browserProvider != null)) {
    throw const MomentsError(
      'An isolated Android session requires one actor on an explicit device, without a browser host',
    );
  }
  final manifestFile = p.join(project, 'moments/manifest.json'), manifest = readManifest(manifestFile);
  if (!(manifest['moments']! as Map).containsKey(name)) throw const MomentsError('Unknown Moment');
  final allocate = adapters.materialization;
  if (allocate == null) throw const MomentsError('A local materialization adapter is required');
  final provider = native ? null : browserSocketProvider(path: browserSocket!, id: browserProvider!);
  final lifecycle = p.join(project, 'moments/.backend');
  makePrivateDirectory(lifecycle, recursive: true);
  final release = await acquireInstanceLock(lifecycle);
  try {
    assertNoManagedSession(lifecycle);
  } on Object {
    await release();
    rethrow;
  }
  final directory = p.join(project, 'moments/.proofs/materializations', uuidV4());
  final record = <String, Object?>{
    'version': 2,
    'workspace': workspaceIdentity(project),
    'supervisor': _supervisor(),
    'name': name,
    'copies': copies,
    'device': ?device,
    'phase': 'allocating',
    'run': null,
    'recovery': null,
  };
  void save(String phase) {
    record['phase'] = phase;
    savePrivateState(p.join(directory, 'session.json'), record);
  }

  final marker = p.join(lifecycle, 'materialization.json');
  try {
    makePrivateDirectory(directory, recursive: true);
    save('allocating');
    savePrivateState(marker, {
      'version': 1,
      'workspace': record['workspace'],
      'directory': directory,
      'supervisor': record['supervisor'],
    });
  } on Object {
    await release();
    rethrow;
  }
  MaterializationProfile? profile;
  Materializer? engine;
  Future<void>? closing;
  var closed = false;
  void aborted() {
    if (signal?.aborted ?? false) throw const MomentsError('Materialization session interrupted');
  }

  Future<void> close() async {
    if (closed) return;
    if (closing != null) return closing;
    closing = () async {
      save('closing');
      // Roots must remain available if actor cleanup is unconfirmed.
      await engine?.close();
      await profile?.cleanup();
      save('closed');
      File(marker).deleteSync();
      closed = true;
    }();
    try {
      await closing;
    } on Object {
      save('attention');
      rethrow;
    } finally {
      closing = null;
      await release();
    }
  }

  try {
    aborted();
    final allocated = profile = allocate(
      MaterializationContext(
        project: project,
        manifestFile: manifestFile,
        manifest: manifest,
        directory: directory,
        name: name,
        copies: copies,
        browserProvider: provider,
        device: device,
      ),
    );
    if (native && allocated.engine.runtime.type != 'ash-flutter-android') {
      throw const MomentsError('The materialization adapter does not support Android actors');
    }
    record['recovery'] = validateRecoveryResources(allocated.recovery);
    save('preparing');
    onProgress?.call({'phase': 'preparing', 'directory': directory});
    await allocated.prepare(signal: signal ?? Interruption(), onProgress: onProgress ?? (_) {});
    aborted();
    final setup = allocated.engine;
    final materializer = engine = Materializer.create(
      project: project,
      manifestFile: manifestFile,
      directory: p.join(directory, 'runs'),
      layers: setup.layers,
      runtime: setup.runtime,
      recipes: setup.recipes,
      scope: setup.scope,
      codeIdentity: allocated.codeIdentity,
    );
    record['run'] = materializer.home;
    save('opening');
    onProgress?.call({'phase': 'opening', 'directory': directory, 'run': materializer.home});
    final worlds = copies == 1 ? [await materializer.open(name)] : await materializer.fork(name, copies);
    aborted();
    final actors = [
      for (final world in worlds)
        {'id': world.id, 'moment': world.name, 'url': _actorUrl(world.runtime), 'instance': world.dir},
    ];
    save('ready');
    return ManagedSession._({
      'version': 1,
      'status': 'ready',
      'directory': directory,
      'run': materializer.home,
      'scope': materializer.scope,
      'actors': actors,
    }, close);
  } on Object catch (error) {
    save('attention');
    try {
      await close();
    } on Object catch (cleanup) {
      String text(Object e) => e is MomentsError ? e.message : '$e';
      throw MomentsError('Materialization needs inspection at $directory: ${text(error)}; cleanup: ${text(cleanup)}');
    }
    rethrow;
  }
}

Object? _actorUrl(Object? handle) => switch (handle) {
  ActorHandle(:final url) => url,
  {'url': final Object url} => url,
  _ => null,
};

/// [interruption] replaces SIGINT/SIGTERM, for callers that own termination.
Interruption _signals(List<StreamSubscription<ProcessSignal>> subscriptions, [Interruption? interruption]) {
  if (interruption != null) return interruption;
  final owned = Interruption();
  for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    subscriptions.add(signal.watch().listen((_) => owned.abort()));
  }
  return owned;
}

Future<void> _cancel(List<StreamSubscription<ProcessSignal>> subscriptions) async {
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}

/// Keeps a materialized session open until Ctrl+C, then closes its actors and
/// discards only its copies.
Future<int> serveManagedSession({
  required String project,
  required String name,
  required ProjectAdapters adapters,
  required int copies,
  String? device,
  String? browserSocket,
  String? browserProvider,
  required void Function(Map<String, Object?> value) emit,
  Interruption? interruption,
}) async {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  interruption = _signals(subscriptions, interruption);
  final stopped = Completer<void>();
  interruption.onAbort(() {
    if (!stopped.isCompleted) stopped.complete();
  });
  ManagedSession? session;
  try {
    session = await openManagedSession(
      project: project,
      name: name,
      adapters: adapters,
      copies: copies,
      device: device,
      browserSocket: browserSocket,
      browserProvider: browserProvider,
      signal: interruption,
      onProgress: (event) => emit({'version': 1, 'status': 'progress', ...event}),
    );
    emit(session.ready);
    await stopped.future;
  } finally {
    try {
      await session?.close();
    } finally {
      await _cancel(subscriptions);
    }
  }
  emit({'version': 1, 'status': 'closed', 'directory': session.ready['directory'], 'run': session.ready['run']});
  return 0;
}

void _privateDirectory(String path) {
  if (realPath(path) != path || entityType(path) != FileSystemEntityType.directory || !private(path)) {
    throw const MomentsError('Managed check requires an owned private directory');
  }
}

Map<String, Object?> _readActorRecord(String path) {
  if (entityType(path) != FileSystemEntityType.file || !private(path) || File(path).lengthSync() > 65536) {
    throw const MomentsError('Invalid private actor record');
  }
  try {
    return asObject(jsonDecode(File(path).readAsStringSync()));
  } on Object {
    throw const MomentsError('Unreadable private actor record');
  }
}

/// An already-live actor found from durable ownership records. Never runs an
/// adapter, allocates resources, prepares data or executes a gesture.
({String project, String name, String manifestFile, Request request, String directory, String actorId})
connectManagedActor(String project, {required String directory, required String name, String? actorId}) {
  project = realPath(project);
  final home = _session(project, directory, 'Session must belong to the selected project');
  final workspace = workspaceIdentity(project);
  _privateDirectory(home);
  final sessionFile = p.join(home, 'session.json'), session = _readActorRecord(sessionFile);
  final supervisor = (session['supervisor'] as Map?)?.cast<String, Object?>();
  if (session['version'] != 2 ||
      session['workspace'] != workspace ||
      session['name'] != name ||
      session['phase'] != 'ready' ||
      !sameProcess(supervisor)) {
    throw const MomentsError('A ready live session for this Moment is required');
  }
  final markerFile = p.join(project, 'moments/.backend/materialization.json'), marker = _readActorRecord(markerFile);
  if (marker['version'] != 1 ||
      marker['workspace'] != workspace ||
      marker['directory'] != home ||
      !deepEqual(marker['supervisor'], supervisor)) {
    throw const MomentsError('Session no longer owns this consumer');
  }
  final runDir = session['run'];
  if (runDir is! String || !isUuid(p.basename(runDir)) || runDir != p.join(home, 'runs', p.basename(runDir))) {
    throw const MomentsError('Invalid session run');
  }
  _privateDirectory(runDir);
  final runFile = p.join(runDir, 'run.json'), run = _readActorRecord(runFile);
  final manifestFile = p.join(project, 'moments/manifest.json'), manifest = readManifest(manifestFile);
  if (run['version'] != 1 ||
      run['runId'] != p.basename(runDir) ||
      run['workspace'] != workspace ||
      !deepEqual(run['supervisor'], supervisor) ||
      !const ['ash-flutter-local', 'ash-flutter-android'].contains(run['runtime']) ||
      run['manifest'] != manifest['recipeHash'] ||
      !sha256Pattern.hasMatch('${run['code'] ?? ''}') ||
      run['layers'] is! List ||
      (run['layers'] as List).length > 32) {
    throw const MomentsError('Session runtime or declaration differs from the current project');
  }
  final actorLayers = (run['layers']! as List).cast<Map>().where((l) => l['type'] == 'flutter-actor').toList();
  if (actorLayers.length != 1 || !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch('${actorLayers.single['name']}')) {
    throw const MomentsError('A single declared Flutter actor layer is required');
  }
  final layerName = actorLayers.single['name']! as String;
  final instances = p.join(runDir, 'instances');
  _privateDirectory(instances);
  final entries = [for (final entry in Directory(instances).listSync()) p.basename(entry.path)];
  if (entries.length > 256 || entries.any((id) => !isUuid(id))) throw const MomentsError('Invalid actor inventory');
  if (actorId != null && (!isUuid(actorId) || !entries.contains(actorId))) {
    throw const MomentsError('Actor does not belong to this session');
  }
  final candidates = <({String id, String dir, String file, Map<String, Object?> value})>[];
  for (final id in actorId != null ? [actorId] : entries) {
    final dir = p.join(instances, id);
    _privateDirectory(dir);
    final file = p.join(dir, 'instance.json'), value = _readActorRecord(file);
    if (value['id'] != id || value['version'] != 1) throw const MomentsError('Invalid actor identity');
    if (value['phase'] == 'ready' && value['name'] == name)
      candidates.add((id: id, dir: dir, file: file, value: value));
  }
  if (candidates.length != 1) {
    throw MomentsError(
      candidates.isNotEmpty
          ? 'Multiple actors are open; select one with --actor <id>'
          : 'No ready actor matches this Moment',
    );
  }
  final actor = candidates.single, world = actor.value;
  final layer = (world['layers'] as Map?)?[layerName] as Map?;
  if (world['materializedMoment'] != name ||
      world['manifest'] != run['manifest'] ||
      world['code'] != run['code'] ||
      layer?['phase'] != 'ready' ||
      layer?['dir'] != p.join(actor.dir, layerName)) {
    throw const MomentsError('Actor does not match its captured situation');
  }
  final layerDir = layer!['dir']! as String;
  _privateDirectory(layerDir);
  final runtimeFile = p.join(layerDir, '.runtime.json'), runtime = _readActorRecord(runtimeFile);
  final url = Uri.tryParse('${runtime['url'] ?? ''}');
  if (url == null) throw const MomentsError('Invalid actor bridge address');
  if (runtime['pid'] != supervisor!['pid'] ||
      url.scheme != 'http' ||
      url.host != '127.0.0.1' ||
      !url.hasPort ||
      url.userInfo.isNotEmpty ||
      !(url.path == '/' || url.path.isEmpty) ||
      url.hasQuery ||
      url.hasFragment ||
      !RegExp(r'^[a-f0-9]{48}$').hasMatch('${runtime['token'] ?? ''}')) {
    throw const MomentsError('Actor bridge is not owned by this supervisor on loopback');
  }
  final records = <(String, Map<String, Object?>)>[
    (sessionFile, session),
    (markerFile, marker),
    (runFile, run),
    (actor.file, world),
    (runtimeFile, runtime),
  ];
  if (run['runtime'] == 'ash-flutter-android') {
    final appFile = p.join(actor.dir, 'android-app.json'), app = _readActorRecord(appFile);
    final transportFile = p.join(actor.dir, 'transport.json'), transport = _readActorRecord(transportFile);
    if (app['version'] != 1 ||
        app['owner'] != actor.id ||
        transport['owner'] != actor.id ||
        app['phase'] != 'running' ||
        transport['phase'] != 'ready' ||
        app['device'] != transport['device'] ||
        session['device'] != 'android:${app['device']}' ||
        app['boot'] != transport['boot'] ||
        !deepEqual(app['supervisor'], supervisor) ||
        !deepEqual(transport['supervisor'], supervisor)) {
      throw const MomentsError('Android actor ownership is not ready');
    }
    records.addAll([(appFile, app), (transportFile, transport)]);
  }
  void current() {
    if (!sameProcess(supervisor) ||
        records.any((entry) => !deepEqual(_readActorRecord(entry.$1), entry.$2)) ||
        readManifest(manifestFile)['recipeHash'] != run['manifest']) {
      throw const MomentsError('Session or actor changed during verification');
    }
  }

  final base = Uri(scheme: 'http', host: '127.0.0.1', port: url.port);
  Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
    if (data != null || !const ['/moments/look', '/moments/inspect', '/dev/status'].contains(path)) {
      throw const MomentsError('Managed verification only permits observation requests');
    }
    current();
    final client = HttpClient();
    try {
      final request = await client.getUrl(base.replace(path: path));
      request
        ..followRedirects = false
        ..headers.set('Authorization', 'Bearer ${runtime['token']}');
      final response = await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw const MomentsError('Owned actor observation unavailable');
      }
      final value = asObject(jsonDecode(await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 15))));
      current();
      if (path == '/moments/look' &&
          !deepEqual(value['materialization'], {
            'instanceId': actor.id,
            'moment': name,
            'from': world['materializedMoment'],
            'manifest': run['manifest'],
          })) {
        throw const MomentsError('Bridge reported a different materialized actor');
      }
      return value;
    } finally {
      client.close(force: true);
    }
  }

  return (
    project: project,
    name: name,
    manifestFile: manifestFile,
    request: request,
    directory: home,
    actorId: actor.id,
  );
}

Future<Map<String, Object?>> checkManagedActor(
  String project, {
  required String directory,
  required String name,
  String? actorId,
}) async {
  final actor = connectManagedActor(project, directory: directory, name: name, actorId: actorId);
  final result = await checkMoment(
    project: actor.project,
    name: actor.name,
    manifestFile: actor.manifestFile,
    request: actor.request,
    materialized: true,
  );
  return {...result, 'name': actor.name, 'session': actor.directory, 'actorId': actor.actorId};
}

/// Infrastructure records only. Never runs the current app adapter, its build,
/// a recipe, authentication, or starts a database or container.
Future<Map<String, Object?>> recoverManagedSession(
  String project, {
  required String directory,
  String? browserSocket,
  String? browserProvider,
}) async {
  project = realPath(project);
  final home = _session(project, directory, 'Session must belong to this project');
  final workspace = workspaceIdentity(project);
  _directory(home);
  final lifecycle = p.join(project, 'moments/.backend');
  makePrivateDirectory(lifecycle, recursive: true);
  return withInstanceLock(lifecycle, () async {
    if (exists(p.join(lifecycle, 'preparation.json'))) {
      throw const MomentsError('A preparation owns this consumer; use moments recover --preparation first');
    }
    final file = p.join(home, 'session.json'), record = _read(file);
    final marker = p.join(lifecycle, 'materialization.json');
    if (record['version'] != 2 ||
        record['workspace'] != workspace ||
        !_supervisorShape(record['supervisor']) ||
        !const [
          'allocating',
          'preparing',
          'opening',
          'ready',
          'closing',
          'attention',
          'closed',
          'recovering',
        ].contains(record['phase'])) {
      throw const MomentsError('Invalid or unsupported session ownership');
    }
    if (sameProcess((record['supervisor']! as Map).cast())) {
      throw const MomentsError('Session supervisor is still alive; stop it before recovery');
    }
    if (exists(marker)) {
      final owner = _read(marker);
      if (owner['version'] != 1 ||
          owner['workspace'] != workspace ||
          owner['directory'] != home ||
          !jsonEqual(owner['supervisor'], record['supervisor'])) {
        throw const MomentsError('Another session owns this consumer');
      }
    }
    final resources = validateRecoveryResources(record['recovery'] ?? {'processes': [], 'containers': [], 'roots': []});
    final instance = (resources['instance'] as Map?)?.cast<String, Object?>();
    if (instance != null) {
      final current = _read(p.join(lifecycle, 'instance.json'));
      if (current['id'] != instance['id'] || current['container'] != instance['container']) {
        throw const MomentsError('Source database ownership changed');
      }
    }
    final processes = (resources['processes']! as List).cast<String>();
    final containers = (resources['containers']! as List).cast<String>();
    final roots = (resources['roots']! as List).cast<Map>();
    final browsers = ((resources['browsers'] as List?) ?? const []).cast<String>();
    for (final name in [...processes, ...containers, ...roots.map((r) => r['name']! as String), ...browsers]) {
      if (exists(p.join(home, name))) _directory(p.join(home, name));
    }
    final runRoot = p.join(home, 'runs'), runs = <String>[];
    if (exists(runRoot)) {
      _directory(runRoot);
      final entries = Directory(runRoot).listSync();
      if (entries.length > 1) throw const MomentsError('Unexpected session run inventory');
      for (final entry in entries) {
        final id = p.basename(entry.path);
        if (!isUuid(id)) throw const MomentsError('Invalid session run');
        final dir = p.join(runRoot, id);
        _directory(dir);
        if (!exists(p.join(dir, 'run.json'))) {
          if (Directory(dir).listSync().isNotEmpty) throw const MomentsError('Unrecorded run resources');
          continue;
        }
        final run = _read(p.join(dir, 'run.json'));
        if (run['workspace'] != workspace || !jsonEqual(run['supervisor'], record['supervisor'])) {
          throw const MomentsError('Run supervisor does not match its session');
        }
        runs.add(dir);
      }
    }
    if (record['run'] != null && !runs.contains(record['run']))
      throw const MomentsError('Session run reference changed');
    if (record['recovery'] == null &&
        (runs.isNotEmpty ||
            Directory(home).listSync().any(
              (v) => !const ['session.json', 'session.json.tmp', '.operation.lock'].contains(p.basename(v.path)),
            ))) {
      throw const MomentsError('Unregistered session resources require inspection');
    }
    final result = <String, Object?>{
      'version': 1,
      'status': 'recovering',
      'directory': home,
      'recipeReplayed': false,
      'verification': 'not-performed',
      'processes': <String>[],
      'containers': <String>[],
      'runs': <String>[],
      'roots': <String>[],
      'browsers': <String>[],
    };
    void save(String phase) {
      record['phase'] = phase;
      savePrivateState(file, record);
      savePrivateState(p.join(home, 'recovery.json'), result);
    }

    void done(String key, String value) {
      (result[key]! as List<String>).add(value);
      save('recovering');
    }

    save('recovering');
    try {
      // Stop creators before looking for partially created children.
      for (final name in processes) {
        final dir = p.join(home, name);
        if (exists(p.join(dir, 'process.json'))) {
          final process = recoverOwnedProcess(dir);
          await process.stop();
          if (process.inspect().present) throw const MomentsError('Session build process remains');
        } else if (exists(dir) && Directory(dir).listSync().isNotEmpty) {
          throw const MomentsError('Unrecorded build process');
        }
        done('processes', name);
      }
      for (final name in containers) {
        final dir = p.join(home, name);
        if (exists(p.join(dir, 'container.json'))) {
          final container = recoverOwnedContainer(dir)..stop();
          if (container.inspect().present) throw const MomentsError('Session build container remains');
        } else if (exists(dir) && Directory(dir).listSync().isNotEmpty) {
          throw const MomentsError('Unrecorded build container');
        }
        done('containers', name);
      }
      // Shared surfaces are not forked worlds. Reconcile their durable browser
      // records before disposing roots, with the same owned-tab boundary.
      for (final name in browsers) {
        final dir = p.join(home, name);
        if (exists(p.join(dir, 'browser.json'))) {
          if (!jsonEqual(_read(p.join(dir, 'browser.json'))['supervisor'], record['supervisor'])) {
            throw const MomentsError('Browser supervisor does not match its session');
          }
          final provider = browserSocket != null && browserProvider != null
              ? browserSocketProvider(path: browserSocket, id: browserProvider)
              : null;
          await recoverBrowserBoundary(dir).close(provider);
        } else if (exists(dir) && Directory(dir).listSync().isNotEmpty) {
          throw const MomentsError('Unrecorded browser resource');
        }
        done('browsers', name);
      }
      for (final dir in runs) {
        await recoverRun(project, directory: dir, browserSocket: browserSocket, browserProvider: browserProvider);
        done('runs', dir);
      }
      for (final root in roots.reversed) {
        final dir = p.join(home, root['name']! as String);
        if (exists(dir)) {
          await _drivers[root['type']]!.recover(
            dir: dir,
            pending: true,
            opts: root['type'] == 'postgres' ? LayerOptions(instance: instance) : LayerOptions(assertStopped: (_) {}),
          );
        }
        done('roots', root['name']! as String);
      }
      result['status'] = 'disposed';
      save('closed');
      if (exists(marker)) File(marker).deleteSync();
      return result;
    } on Object {
      result['status'] = 'attention';
      save('attention');
      rethrow;
    }
  });
}

/// Same ownership boundary and recovery journal as materialized sessions; one
/// process, not an additional supervisor. Application code supplies resources.
Future<Map<String, Object?>> runManagedComposition({
  required String project,
  required String planFile,
  required String profile,
  required String browserSocket,
  required String browserProvider,
  required ProjectAdapters adapters,
  Interruption? signal,
  void Function(Map<String, Object?> event)? onProgress,
}) async {
  project = realPath(project);
  if (!_segment.hasMatch(profile)) throw const MomentsError('Select a named composition profile');
  final planPath = p.normalize(p.absolute(planFile));
  if (entityType(planPath) != FileSystemEntityType.file || File(planPath).lengthSync() > 65536) {
    throw const MomentsError('A bounded composition plan file is required');
  }
  final plan = jsonDecode(File(planPath).readAsStringSync());
  final manifestFile = p.join(project, 'moments/manifest.json'), manifest = readManifest(manifestFile);
  // Before running adapter code or taking ownership.
  compileComposition(plan, manifest);
  final allocate = adapters.composition;
  if (allocate == null) throw const MomentsError('A local composition adapter is required');
  final provider = browserSocketProvider(path: browserSocket, id: browserProvider);
  final lifecycle = p.join(project, 'moments/.backend');
  makePrivateDirectory(lifecycle, recursive: true);
  final release = await acquireInstanceLock(lifecycle);
  try {
    assertNoManagedSession(lifecycle);
  } on Object {
    await release();
    rethrow;
  }
  final directory = p.join(project, 'moments/.proofs/materializations', uuidV4());
  final record = <String, Object?>{
    'version': 2,
    'kind': 'composition',
    'workspace': workspaceIdentity(project),
    'supervisor': _supervisor(),
    'name': null,
    'profile': profile,
    'phase': 'allocating',
    'run': null,
    'recovery': null,
  };
  final marker = p.join(lifecycle, 'materialization.json');
  final composition = <String, Object?>{};
  final report = <String, Object?>{
    'version': 1,
    'kind': 'managed-composition',
    'status': 'running',
    'directory': directory,
    'composition': composition,
  };
  void save(String phase) {
    record['phase'] = phase;
    savePrivateState(p.join(directory, 'session.json'), record);
    savePrivateState(p.join(directory, 'composition-report.json'), report);
  }

  void active() {
    if (signal?.aborted ?? false)
      throw const MomentsError('Composition interrupted; inspect effects before another execution');
  }

  CompositionProfile? allocated;
  try {
    makePrivateDirectory(directory, recursive: true);
    save('allocating');
    savePrivateState(marker, {
      'version': 1,
      'workspace': record['workspace'],
      'directory': directory,
      'supervisor': record['supervisor'],
    });
    savePrivateState(p.join(directory, 'plan.json'), plan);
    active();
    final adapter = allocated = allocate(
      CompositionContext(
        project: project,
        manifestFile: manifestFile,
        manifest: manifest,
        directory: directory,
        plan: jsonCopy(plan),
        profile: profile,
        browserProvider: provider,
      ),
    );
    record['recovery'] = validateRecoveryResources(adapter.recovery);
    save('preparing');
    onProgress?.call({'status': 'progress', 'phase': 'preparing', 'directory': directory});
    await adapter.prepare(signal: signal ?? Interruption());
    active();
    void unchanged(String when) {
      if (readManifest(manifestFile)['recipeHash'] != manifest['recipeHash']) {
        throw MomentsError('Moment declaration changed $when');
      }
    }

    unchanged('during preparation');
    save('ready');
    onProgress?.call({'status': 'progress', 'phase': 'executing', 'directory': directory});
    await executeComposition(
      plan: plan,
      manifest: manifest,
      connect: adapter.connect,
      report: composition,
      signal: signal,
      beforeStage: (id) async {
        active();
        unchanged('during execution');
        await adapter.beforeStage?.call(id);
      },
      afterStage: adapter.afterStage,
      onProgress: (_) => save('ready'),
    );
    active();
    report['adapter'] = await adapter.verify?.call();
    active();
    unchanged('before composition completion');
    report['status'] = 'passed';
  } on Object {
    report['status'] = composition['status'] == 'failed' ? 'failed' : 'unavailable';
    // Adapter exceptions may contain private inputs. Keep the public reason
    // generic; stage receipts already contain safe protocol diagnostics.
    report['reason'] = 'Composition did not complete; inspect its stage receipts and owned resources';
  } finally {
    try {
      save('closing');
      await allocated?.cleanup(passed: report['status'] == 'passed');
      report['resourcesClosed'] = true;
      save('closed');
      File(marker).deleteSync();
    } on Object {
      report
        ..['status'] = 'unavailable'
        ..['resourcesClosed'] = false
        ..['reason'] = 'Composition cleanup unconfirmed; stop the supervisor and use moments recover --session';
      save('attention');
    } finally {
      await release();
    }
  }
  final exitCode = switch (report['status']) {
    'passed' => 0,
    'failed' => 1,
    _ => 2,
  };
  return {...report, 'exitCode': exitCode, 'report': p.join(directory, 'composition-report.json')};
}

Future<Map<String, Object?>> serveManagedComposition({
  required String project,
  required String planFile,
  required String profile,
  required String browserSocket,
  required String browserProvider,
  required ProjectAdapters adapters,
  required void Function(Map<String, Object?> value) emit,
  Interruption? interruption,
}) async {
  final subscriptions = <StreamSubscription<ProcessSignal>>[];
  interruption = _signals(subscriptions, interruption);
  try {
    return await runManagedComposition(
      project: project,
      planFile: planFile,
      profile: profile,
      browserSocket: browserSocket,
      browserProvider: browserProvider,
      adapters: adapters,
      signal: interruption,
      onProgress: emit,
    );
  } finally {
    await _cancel(subscriptions);
  }
}

/// Runs the project's preparation adapter for a fresh profile.
Future<Map<String, Object?>> prepareProfile(
  String project, {
  required String profile,
  required ProjectAdapters adapters,
  required void Function(Map<String, Object?> event) onProgress,
}) async {
  final prepare = adapters.preparation;
  if (prepare == null) throw const MomentsError('A local preparation adapter is required');
  final result = await prepare(project: project, profile: profile, onProgress: onProgress);
  if (!const ['prepared', 'unavailable'].contains(result['status']) || result['servicesClosed'] is! bool) {
    throw const MomentsError('Preparation adapter returned an invalid result');
  }
  return result;
}

final _pathPattern = RegExp(r'^[a-z0-9-]+(?:/[a-z0-9-]+)*$');
bool _field(Object? value) => value is String && RegExp(r'^[a-z][a-zA-Z0-9]{0,63}$').hasMatch(value);

Map<String, Object?> _privateRead(String file) =>
    readJsonObject(file, 262144, 'Invalid private preparation record', privateOnly: true);

String _ownedDirectory(String project, String input) {
  final home = p.normalize(p.absolute(input)), proofs = p.join(realPath(project), 'moments/.proofs');
  final local = p.relative(home, from: proofs);
  if (local == '.' || local == '..' || local.startsWith('../') || !p.isWithin(proofs, home)) {
    throw const MomentsError('Preparation must belong to the selected project');
  }
  if (realPath(home) != home || entityType(home) != FileSystemEntityType.directory || !private(home)) {
    throw const MomentsError('Preparation directory must be private and owned');
  }
  return home;
}

Map<String, Object?> validatePreparationResources(Object? resources) {
  bool bounded(Object? list) => list is List && list.length <= 32;
  if (resources is! Map ||
      !bounded(resources['processes']) ||
      !bounded(resources['containers']) ||
      !bounded(resources['services'])) {
    throw const MomentsError('Declare bounded preparation resources');
  }
  final paths = [...(resources['processes'] as List), ...(resources['containers'] as List)];
  if (paths.any((path) => path is! String || !_pathPattern.hasMatch(path)) || paths.toSet().length != paths.length) {
    throw const MomentsError('Invalid preparation process/container paths');
  }
  for (final service in resources['services'] as List) {
    final record = service is Map ? service['record'] : null;
    final stop = service is Map ? service['stop'] : null, preserve = service is Map ? service['preserve'] : null;
    if (record is! String ||
        !_pathPattern.hasMatch(record.replaceFirst(RegExp(r'\.json$'), '')) ||
        !record.endsWith('.json') ||
        !_field((service as Map)['ownerField']) ||
        !RegExp(r'^dev\.[a-z0-9.-]{1,96}$').hasMatch('${service['label'] ?? ''}') ||
        stop is! List ||
        preserve is! List ||
        stop.length + preserve.length > 8 ||
        [...stop, ...preserve].any((v) => !_field(v)) ||
        {...stop, ...preserve}.length != stop.length + preserve.length) {
      throw const MomentsError('Invalid preparation service ownership');
    }
  }
  return asObject(jsonCopy(resources));
}

String _inside(String home, String path) {
  var current = home;
  for (final part in path.split('/')) {
    current = p.join(current, part);
    if (entityType(current) == FileSystemEntityType.link) {
      throw const MomentsError('Preparation recovery refuses symbolic resource paths');
    }
  }
  return current;
}

({String lifecycle, String marker}) _preparationMarker(String project) {
  final lifecycle = p.join(realPath(project), 'moments/.backend');
  makePrivateDirectory(lifecycle, recursive: true);
  return (lifecycle: lifecycle, marker: p.join(lifecycle, 'preparation.json'));
}

bool _ownsMarker(String marker, String home, Map<String, Object?> record) {
  if (!exists(marker)) return false;
  final owner = _privateRead(marker);
  if (owner['version'] != 1 ||
      owner['workspace'] != record['workspace'] ||
      owner['id'] != record['id'] ||
      owner['directory'] != home) {
    throw const MomentsError('Another preparation owns this consumer');
  }
  return true;
}

void _clearMarker(String lifecycle, String marker, String home, Map<String, Object?> record) {
  if (_ownsMarker(marker, home, record)) {
    File(marker).deleteSync();
    syncDirectory(lifecycle);
  }
}

/// Holds the consumer's lock for the complete preparation. The durable marker
/// outlives a killed supervisor and keeps new work from racing its children.
Future<({Future<void> Function() close, Future<void> Function() attention})> registerPreparation({
  required String project,
  required String directory,
  required Map<String, Object?> resources,
}) async {
  final home = _ownedDirectory(project, directory), file = p.join(home, 'preparation-ownership.json');
  final (:lifecycle, :marker) = _preparationMarker(project);
  final release = await acquireInstanceLock(lifecycle);
  try {
    assertNoManagedSession(lifecycle);
    if (exists(file)) throw const MomentsError('Preparation ownership already exists');
    final record = <String, Object?>{
      'version': 1,
      'kind': 'preparation',
      'id': uuidV4(),
      'workspace': workspaceIdentity(project),
      'supervisor': _supervisor(),
      'phase': 'active',
      'resources': validatePreparationResources(resources),
    };
    // A crash between these saves has created no resources yet. Recovery can
    // close the journal even if the marker was never published.
    savePrivateState(file, record);
    savePrivateState(marker, {'version': 1, 'id': record['id'], 'workspace': record['workspace'], 'directory': home});
    var finished = false;
    Future<void> finish(String phase) async {
      if (finished) return;
      try {
        _ownsMarker(marker, home, record);
        record['phase'] = phase;
        savePrivateState(file, record);
        if (phase == 'closed') _clearMarker(lifecycle, marker, home, record);
      } finally {
        finished = true;
        await release();
      }
    }

    return (close: () => finish('closed'), attention: () => finish('attention'));
  } on Object {
    await release();
    rethrow;
  }
}

String _preparationDocker(List<String> args) {
  final result = Process.runSync('docker', args);
  if (result.exitCode != 0) throw const MomentsError('Preparation container operation unconfirmed');
  return (result.stdout as String).trim();
}

/// Infrastructure only: no adapters, builds, migrations, SQL, recipes or
/// automatic restarts. Databases declared preserved are observed, not stopped.
Future<Map<String, Object?>> recoverPreparation(
  String project, {
  required String directory,
  String Function(List<String> args) docker = _preparationDocker,
}) async {
  project = realPath(project);
  final home = _ownedDirectory(project, directory);
  final (:lifecycle, :marker) = _preparationMarker(project);
  return withInstanceLock(
    lifecycle,
    () => withInstanceLock(home, () async {
      final file = p.join(home, 'preparation-ownership.json'), record = _privateRead(file);
      if (record['version'] != 1 ||
          record['kind'] != 'preparation' ||
          !isUuid(record['id']) ||
          record['workspace'] != workspaceIdentity(project) ||
          !_supervisorShape(record['supervisor']) ||
          !const ['active', 'attention', 'recovering', 'closed'].contains(record['phase'])) {
        throw const MomentsError('Invalid preparation ownership');
      }
      if (sameProcess((record['supervisor']! as Map).cast())) {
        throw const MomentsError('Preparation supervisor is still alive; stop it before recovery');
      }
      final resources = validatePreparationResources(record['resources']);
      final pins = record['serviceIds'];
      if (record.containsKey('serviceIds') &&
          (pins is! Map || pins.length > 256 || pins.values.any((id) => !sha256Pattern.hasMatch('$id')))) {
        throw const MomentsError('Invalid preparation service pins');
      }
      final serviceIds = record['serviceIds'] = (pins as Map? ?? {}).cast<String, Object?>();
      // Completed preparations may since have lent their database or API to
      // another composition. Never touch those resources through an old receipt.
      if (record['phase'] == 'closed') {
        // Finish a crash between the closed receipt and marker removal. An
        // unrelated later owner's marker stays untouched.
        if (exists(marker) && _privateRead(marker)['id'] == record['id']) _clearMarker(lifecycle, marker, home, record);
        return {
          'status': 'closed',
          'directory': home,
          'alreadyClosed': true,
          'recipeReplayed': false,
          'resourcesTouched': false,
        };
      }
      if (exists(p.join(lifecycle, 'materialization.json'))) {
        throw const MomentsError('A materialization session owns this consumer');
      }
      _ownsMarker(marker, home, record);
      final services = <Map<String, Object?>>[];
      final result = <String, Object?>{
        'status': 'recovering',
        'directory': home,
        'recipeReplayed': false,
        'verification': 'not-performed',
        'processes': <String>[],
        'containers': <String>[],
        'services': services,
      };
      void save(String phase) {
        record['phase'] = phase;
        savePrivateState(file, record);
        savePrivateState(p.join(home, 'preparation-recovery.json'), result);
      }

      save('recovering');
      try {
        for (final path in (resources['processes']! as List).cast<String>()) {
          final dir = _inside(home, path);
          if (exists(p.join(dir, 'process.json'))) {
            final process = recoverOwnedProcess(dir);
            await process.stop();
            if (process.inspect().running) throw const MomentsError('Preparation creator remains active');
          } else if (exists(dir) && Directory(dir).listSync().isNotEmpty) {
            throw const MomentsError('Unrecorded preparation process requires inspection');
          }
          (result['processes']! as List<String>).add(path);
          save('recovering');
        }
        for (final path in (resources['containers']! as List).cast<String>()) {
          final dir = _inside(home, path);
          if (exists(p.join(dir, 'container.json'))) {
            final container = recoverOwnedContainer(dir)..stop();
            if (container.inspect().present) throw const MomentsError('Preparation compiler remains');
          } else if (exists(dir) && Directory(dir).listSync().isNotEmpty) {
            throw const MomentsError('Unrecorded preparation container requires inspection');
          }
          (result['containers']! as List<String>).add(path);
          save('recovering');
        }
        for (final service in (resources['services']! as List).cast<Map>()) {
          final path = _inside(home, service['record']! as String);
          if (!exists(path)) continue;
          final owner = _privateRead(path), id = owner[service['ownerField']];
          if (!isUuid(id)) throw const MomentsError('Invalid preparation service owner');
          Map<String, Object?>? locate(Object? name) {
            if (name is! String || !RegExp(r'^[a-z][a-z0-9-]{0,160}$').hasMatch(name) || !name.endsWith('-$id')) {
              throw const MomentsError('Invalid preparation service name');
            }
            List<String> ids() => docker([
              'ps',
              '-aq',
              '--no-trunc',
              '--filter',
              'name=^/$name\$',
            ]).split(RegExp(r'\s+')).where((v) => v.isNotEmpty).toList();
            final found = ids();
            if (found.isEmpty) return null;
            if (found.length != 1 || !sha256Pattern.hasMatch(found.single)) {
              throw const MomentsError('Ambiguous preparation service identity');
            }
            String inspection;
            try {
              inspection = docker(['inspect', found.single]);
            } on Object {
              // --rm may complete between list and inspect. Confirm absence with
              // a fresh successful query; an inspect failure alone proves nothing.
              if (ids().isEmpty) return null;
              rethrow;
            }
            final value = ((jsonDecode(inspection) as List).firstOrNull as Map?)?.cast<String, Object?>();
            if (value?['Id'] != found.single ||
                value?['Name'] != '/$name' ||
                ((value?['Config'] as Map?)?['Labels'] as Map?)?[service['label']] != id) {
              throw const MomentsError('Preparation service ownership changed');
            }
            if (serviceIds[name] != null && serviceIds[name] != value!['Id']) {
              throw const MomentsError('Preparation service was replaced after recovery started');
            }
            return value;
          }

          final stop = (service['stop']! as List).cast<String>(),
              preserve = (service['preserve']! as List).cast<String>();
          for (final key in [...stop, ...preserve]) {
            final name = owner[key], observed = locate(name), preserved = preserve.contains(key);
            if (observed != null && !preserved && (observed['State'] as Map?)?['Running'] == true) {
              // Pin the observed ID before the side effect. Stop by ID, never by name.
              serviceIds[name! as String] = observed['Id'];
              services.add({'name': name, 'id': observed['Id'], 'status': 'stopping'});
              save('recovering');
              docker(['stop', '--time', '5', observed['Id']! as String]);
              final after = locate(name);
              if (after != null && (after['Id'] != observed['Id'] || (after['State'] as Map?)?['Running'] == true)) {
                throw const MomentsError('Preparation service stop unconfirmed');
              }
            }
            services.add({
              'name': name,
              'status': preserved
                  ? 'preserved'
                  : observed != null
                  ? 'stopped'
                  : 'absent',
            });
            save('recovering');
          }
        }
        result['status'] = 'closed';
        save('closed');
        _clearMarker(lifecycle, marker, home, record);
        return result;
      } on Object {
        result['status'] = 'attention';
        save('attention');
        rethrow;
      }
    }),
  );
}
