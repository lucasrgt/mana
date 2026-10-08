import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson, processIdentity, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'journey.dart';
import 'layers.dart';
import 'lifecycle.dart';
import 'manifest.dart';
import 'private_fs.dart';
import 'protocol.dart';

/// One materialized copy of a Moment: its layer copies and, once started, the
/// runtime handle that serves them.
final class World {
  World({
    required this.id,
    required this.name,
    required this.dir,
    required this.materializedMoment,
    required this.manifest,
  });
  final String id, name, dir;
  final String manifest;
  String? materializedMoment;
  final handles = <String, LayerHandle>{};
  final pendingLayers = <String, String>{};
  final layerState = <String, Map<String, Object?>>{};
  Object? runtime;

  Map<String, Object?> get materialization => {
    'instanceId': id,
    'moment': name,
    'from': materializedMoment,
    'manifest': manifest,
  };
}

/// Starts and stops the app for a world. [allocate] returns the ownership
/// handle synchronously, before any side effect, so a failed start stays
/// stoppable.
abstract interface class MaterializerRuntime {
  String get type;
  Object allocate(World world);
  Future<void> start(Object handle, World world);
  Future<void> stop(Object handle);

  /// Gesture journeys, when this runtime has an actor that can perform them.
  Future<Map<String, Object?>> Function(
    World world, {
    required String manifestFile,
    required String name,
    bool navigation,
    void Function()? assertCurrent,
  })?
  get executeJourney;
}

/// A backend transition that turns the parent situation into this Moment.
typedef TransitionRecipe = Future<void> Function(World world);

typedef Snapshot = ({
  String id,
  String name,
  String dir,
  Map<String, String> layers,
  Map<String, String> pendingLayers,
});

final _captureId = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');

/// Layer coordinator. Receipts name their scope explicitly; this does not make
/// a single-runtime launcher capable of restoring ancestors.
final class Materializer {
  Materializer._({
    required this.manifestFile,
    required this.layers,
    required this.recipes,
    required this.runtime,
    required this.codeIdentity,
    required this.scope,
    required this.runId,
    required this.home,
    required Manifest manifest,
    required String identity,
  }) : _manifest = manifest,
       _identity = identity,
       _log = p.join(home, 'events.jsonl');

  factory Materializer.create({
    required String manifestFile,
    required String directory,
    required List<Layer> layers,
    Map<String, TransitionRecipe> recipes = const {},
    required MaterializerRuntime runtime,
    required String Function() codeIdentity,
    required String scope,
    String? project,
  }) {
    final name = RegExp(r'^[a-z][a-z0-9-]*$');
    if (layers.isEmpty ||
        layers.map((l) => l.name).toSet().length != layers.length ||
        layers.any((l) => !name.hasMatch(l.name) || !name.hasMatch(l.driver.type) || l.root.isEmpty)) {
      throw const MomentsError('Materialization needs named layers with explicit captured roots');
    }
    if (scope.isEmpty) throw const MomentsError('Declare scope, runtime lifecycle and code identity');
    final manifest = readManifest(manifestFile), identity = codeIdentity();
    if (!sha256Pattern.hasMatch(identity)) throw const MomentsError('Code identity must be a SHA-256 fingerprint');
    final runId = uuidV4();
    makePrivateDirectory(directory, recursive: true);
    final home = p.join(p.normalize(p.absolute(directory)), runId);
    makePrivateDirectory(home);
    final supervisor = processIdentity(pid);
    if (supervisor == null) throw const MomentsError('Cannot identify materializer supervisor');
    savePrivateState(p.join(home, 'run.json'), {
      'version': 1,
      'runId': runId,
      'scope': scope,
      'code': identity,
      'manifest': manifest['recipeHash'],
      'supervisor': identityJson(supervisor),
      if (project != null) 'workspace': workspaceIdentity(project),
      'runtime': runtime.type,
      'layers': [
        for (final layer in layers) {'name': layer.name, 'type': layer.driver.type},
      ],
    });
    final materializer = Materializer._(
      manifestFile: manifestFile,
      layers: layers,
      recipes: recipes,
      runtime: runtime,
      codeIdentity: codeIdentity,
      scope: scope,
      runId: runId,
      home: home,
      manifest: manifest,
      identity: identity,
    );
    materializer._event('run.started', null, {
      'protocol': protocol,
      'manifest': manifest['recipeHash'],
      'code': identity,
    });
    return materializer;
  }

  final String manifestFile, scope, runId, home;
  final List<Layer> layers;
  final Map<String, TransitionRecipe> recipes;
  final MaterializerRuntime runtime;
  final String Function() codeIdentity;
  final Manifest _manifest;
  final String _identity, _log;
  var _sequence = 0;
  var _closed = false, _closing = false;
  Future<void>? _closeAttempt;
  final _disposed = Expando<bool>();
  final _operations = <Future<Object?>>{};
  final _snapshots = <String, Snapshot>{};
  final _builds = <String, Future<Snapshot>>{};
  final _worlds = <World>{};

  String get _recipeHash => _manifest['recipeHash']! as String;
  Map<String, Object?> get _moments => (_manifest['moments']! as Map).cast();

  Future<T> _track<T>(Future<T> Function() operation) {
    if (_closing || _closed) return Future.error(const MomentsError('Materializer is closing'));
    final future = Future(operation);
    _operations.add(future);
    future.then((_) => _operations.remove(future), onError: (_) => _operations.remove(future));
    return future;
  }

  void _event(String type, String? name, [Map<String, Object?> details = const {}]) {
    final value = {
      'version': 1,
      'runId': runId,
      'sequence': ++_sequence,
      'type': type,
      'moment': name,
      'scope': scope,
      'at': DateTime.now().toUtc().toIso8601String(),
      ...details,
    };
    final file = File(_log);
    final fresh = !file.existsSync();
    final handle = file.openSync(mode: FileMode.append);
    try {
      if (fresh) Process.runSync('chmod', ['600', _log]);
      handle
        ..writeStringSync('${jsonEncode(value)}\n')
        ..flushSync();
    } finally {
      handle.closeSync();
    }
  }

  void _current() {
    if (_closed) throw const MomentsError('Materializer is closed');
    if (codeIdentity() != _identity || readManifest(manifestFile)['recipeHash'] != _recipeHash) {
      throw const MomentsError('Code or Moment declaration changed; start an explicit new materialization');
    }
  }

  ({Map<String, Object?> scene, TransitionRecipe? recipe}) _selection(String name) {
    final scene = (_moments[name] as Map?)?.cast<String, Object?>();
    if (scene == null) throw const MomentsError('Unknown Moment');
    if ((scene['steps'] as List?)?.isNotEmpty ?? false) {
      if (runtime.executeJourney == null) {
        throw const MomentsError(
          'Gesture journeys need an actor-capable materializer; backend transitions cannot silently skip steps',
        );
      }
      validateSteps({...scene, 'checks': scene['checks'] ?? const []}, navigation: true);
      return (scene: scene, recipe: null);
    }
    final recipe = recipes[(scene['backend'] as Map?)?['recipe']];
    if (recipe == null) throw const MomentsError('Moment needs a registered transition recipe');
    return (scene: scene, recipe: recipe);
  }

  /// Resolves the whole chain before allocating any resources.
  void _preflight(String name) {
    _current();
    for (String? node = name; node != null; node = _selection(node).scene['from'] as String?) {
      _selection(node);
    }
  }

  void _checkpoint(World world, String phase) => savePrivateState(p.join(world.dir, 'instance.json'), {
    'version': 1,
    'id': world.id,
    'name': world.name,
    'materializedMoment': world.materializedMoment,
    'phase': phase,
    'layers': world.layerState,
    'scope': scope,
    'code': _identity,
    'manifest': _recipeHash,
  });

  Future<void> _stop(World world) async {
    final handle = world.runtime;
    if (handle == null) return;
    await runtime.stop(handle);
    world.runtime = null;
    _checkpoint(world, 'stopped');
    _event('runtime.stopped', world.name, {'instanceId': world.id});
  }

  Future<void> _dispose(World world) async {
    if (_disposed[world] == true) return;
    if (!_worlds.contains(world)) throw const MomentsError('Instance does not belong to this materializer');
    await _stop(world);
    for (final layer in layers.reversed) {
      if (world.handles[layer.name] case final handle?) {
        await layer.driver.dispose(handle: handle, opts: layer.opts);
        world.handles.remove(layer.name);
      } else if (world.pendingLayers[layer.name] case final pending?) {
        await layer.driver.recover(dir: pending, opts: layer.opts, pending: true);
        world.pendingLayers.remove(layer.name);
      } else {
        continue;
      }
      world.layerState[layer.name]!['phase'] = 'disposed';
      _checkpoint(world, 'disposing');
    }
    _worlds.remove(world);
    _disposed[world] = true;
    _checkpoint(world, 'disposed');
    _event('instance.disposed', world.name, {'instanceId': world.id});
  }

  Future<World> _materialize(String name, Snapshot? parent) async {
    _current();
    final id = uuidV4(), dir = p.join(home, 'instances', id);
    makePrivateDirectory(dir, recursive: true);
    final world = World(id: id, name: name, dir: dir, materializedMoment: parent?.name, manifest: _recipeHash);
    _worlds.add(world);
    _checkpoint(world, 'materializing');
    _event('materialization.started', name, {
      'instanceId': id,
      'fromSnapshot': parent?.id,
      'materializedMoment': world.materializedMoment,
    });
    try {
      for (final layer in layers) {
        final destination = p.join(dir, layer.name);
        world.pendingLayers[layer.name] = destination;
        world.layerState[layer.name] = {'dir': destination, 'phase': 'materializing'};
        _checkpoint(world, 'materializing');
        world.handles[layer.name] = await layer.driver.materialize(
          dir: destination,
          from: parent?.layers[layer.name] ?? layer.root,
          opts: layer.opts,
        );
        world.pendingLayers.remove(layer.name);
        world.layerState[layer.name]!['phase'] = 'ready';
        _checkpoint(world, 'materializing');
      }
      _current();
      _event('layers.materialized', name, {
        'instanceId': id,
        'fromSnapshot': parent?.id,
        'materializedMoment': world.materializedMoment,
      });
      // A synchronous ownership handle exists before any runtime side effect.
      world.runtime = runtime.allocate(world);
      await runtime.start(world.runtime!, world);
      _current();
      _event('runtime.ready', name, {'instanceId': id, 'materializedMoment': world.materializedMoment});
      _checkpoint(world, 'ready');
      return world;
    } on Object {
      _checkpoint(world, 'attention');
      _event('materialization.failed', name, {'instanceId': id});
      rethrow;
    }
  }

  static bool _capture(Object? value, String name) =>
      value is Map &&
      value['status'] == 'captured' &&
      value['name'] == name &&
      _captureId.hasMatch('${value['id'] ?? ''}') &&
      value['client'] is String &&
      (value['client'] as String).isNotEmpty &&
      value['revision'] is String &&
      (value['revision'] as String).isNotEmpty &&
      value['sequence'] is int &&
      (value['sequence'] as int) > 0;

  void _verifyNavigation(Map<String, Object?> result, Map<String, Object?> scene, World world, String name) {
    final context = result['materialization'] as Map?;
    final steps = (scene['steps']! as List).cast<Map>();
    final reported = result['steps'];
    final capture = result['capture'] as Map?;
    bool stepsOk() {
      if (reported is! List || reported.length != steps.length) return false;
      for (final (index, step) in reported.indexed) {
        if (step is! Map ||
            step['name'] != steps[index]['name'] ||
            step['status'] != 'passed' ||
            step['dispatch'] != 'dispatched' ||
            !_capture(step['capture'], name)) {
          return false;
        }
        final stepCapture = step['capture'] as Map;
        final last = index + 1 >= reported.length;
        final next = last ? null : ((reported[index + 1] as Map)['capture'] as Map?)?['sequence'];
        if (stepCapture['client'] != capture!['client'] ||
            stepCapture['revision'] != capture['revision'] ||
            (stepCapture['sequence']! as int) >= ((next ?? capture['sequence']) as int)) {
          return false;
        }
      }
      return true;
    }

    if (result['status'] != 'captured' ||
        result['operation'] != 'materialized-navigation' ||
        result['name'] != name ||
        (result['ownership'] as Map?)?['phase'] != 'idle' ||
        context?['instanceId'] != world.id ||
        context?['moment'] != name ||
        context?['from'] != world.materializedMoment ||
        context?['manifest'] != _recipeHash ||
        !_capture(capture, name) ||
        !const ['not-performed', 'step-criteria-only'].contains(result['verification']) ||
        result['checks'] is! List ||
        (result['checks'] as List).isNotEmpty ||
        !stepsOk()) {
      throw const MomentsError('Materialized navigation lacks an owned fresh UI capture; no snapshot created');
    }
  }

  Future<Snapshot> _build(String name) {
    _preflight(name);
    return _builds[name] ??= () async {
      final (:scene, :recipe) = _selection(name);
      final from = scene['from'] as String?;
      final parent = from != null ? await _build(from) : null;
      final world = await _materialize(name, parent);
      try {
        final transitionId = uuidV4();
        _event('transition.started', name, {'instanceId': world.id, 'transitionId': transitionId, 'from': from});
        if ((scene['steps'] as List?)?.isNotEmpty ?? false) {
          final result = await runtime.executeJourney!(
            world,
            manifestFile: manifestFile,
            name: name,
            navigation: true,
            assertCurrent: _current,
          );
          _verifyNavigation(result, scene, world, name);
          savePrivateState(p.join(world.dir, 'journey.json'), result);
        } else {
          await recipe!(world);
        }
        _current();
        world.materializedMoment = name;
        _checkpoint(world, 'transition-completed');
        _event('transition.completed', name, {'instanceId': world.id, 'transitionId': transitionId, 'from': from});
        await _stop(world);
        _current();
        final id = uuidV4(), dir = p.join(home, 'snapshots', id);
        final snapshot = (id: id, name: name, dir: dir, layers: <String, String>{}, pendingLayers: <String, String>{});
        Map<String, Object?> record(String phase) => {
          'id': id,
          'name': name,
          'dir': dir,
          'layers': snapshot.layers,
          'pendingLayers': snapshot.pendingLayers,
          'scope': scope,
          'code': _identity,
          'manifest': _recipeHash,
          'phase': phase,
        };
        makePrivateDirectory(dir, recursive: true);
        _event('capture.started', name, {'instanceId': world.id, 'snapshotId': id});
        // Track partial captures for explicit cleanup as well as successful ones.
        _snapshots[id] = snapshot;
        for (final layer in layers) {
          final out = p.join(dir, layer.name);
          snapshot.pendingLayers[layer.name] = out;
          savePrivateState(p.join(dir, 'snapshot.json'), record('capturing'));
          await layer.driver.capture(handle: world.handles[layer.name]!, out: out, opts: layer.opts);
          snapshot.layers[layer.name] = out;
          snapshot.pendingLayers.remove(layer.name);
        }
        _current();
        savePrivateState(p.join(dir, 'snapshot.json'), record('ready'));
        _event('snapshot.ready', name, {'instanceId': world.id, 'snapshotId': id});
        return snapshot;
      } on Object {
        _checkpoint(world, 'attention');
        _event('build.failed', name, {'instanceId': world.id});
        rethrow;
      } finally {
        await _dispose(world);
      }
    }();
  }

  Future<Snapshot> build(String name) => _track(() => _build(name));

  Future<World> open(String name) => _track(() async => _materialize(name, await _build(name)));

  Future<List<World>> fork(String name, [int count = 2]) => _track(() async {
    if (count < 1 || count > 32) throw const MomentsError('Fork count must be 1–32');
    final snapshot = await _build(name);
    return [for (var i = 0; i < count; i++) await _materialize(name, snapshot)];
  });

  Future<void> dispose(World world) => _track(() => _dispose(world));

  /// Cleanup only. No automatic replay, even after a failed transition.
  Future<void> close() {
    final attempt = _closeAttempt ??= () async {
      _closing = true;
      await Future.wait(_operations.map((f) => f.then<void>((_) {}, onError: (_) {})));
      final errors = <Object>[];
      for (final world in [..._worlds]) {
        try {
          await _dispose(world);
        } on Object catch (error) {
          errors.add(error);
        }
      }
      for (final snapshot in _snapshots.values) {
        for (final layer in layers.reversed) {
          try {
            if (snapshot.pendingLayers[layer.name] case final pending?) {
              await layer.driver.recover(dir: pending, opts: layer.opts, pending: true);
              snapshot.pendingLayers.remove(layer.name);
            } else if (snapshot.layers[layer.name] case final captured?) {
              await layer.driver.forget(dir: captured, opts: layer.opts);
              snapshot.layers.remove(layer.name);
            } else {
              continue;
            }
            savePrivateState(p.join(snapshot.dir, 'snapshot.json'), {
              'id': snapshot.id,
              'name': snapshot.name,
              'dir': snapshot.dir,
              'layers': snapshot.layers,
              'pendingLayers': snapshot.pendingLayers,
              'scope': scope,
              'code': _identity,
              'manifest': _recipeHash,
              'phase': snapshot.layers.isNotEmpty || snapshot.pendingLayers.isNotEmpty ? 'disposing' : 'disposed',
            });
          } on Object catch (error) {
            errors.add(error);
          }
        }
      }
      _closed = true;
      _event(errors.isNotEmpty ? 'cleanup.failed' : 'closed', null);
      syncDirectory(home);
      if (errors.isNotEmpty) {
        throw MomentsError(
          'Materialization cleanup needs inspection: ${errors.map((e) => e is MomentsError ? e.message : '$e').join('; ')}',
        );
      }
    }();
    attempt.catchError((_) {
      _closeAttempt = null;
    });
    return attempt;
  }
}
