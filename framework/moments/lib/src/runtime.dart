import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show openPrivate, uuidV4;
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'dart_sources.dart';
import 'errors.dart';
import 'format.dart';
import 'http_server.dart';
import 'json.dart';
import 'manifest.dart';
import 'projection.dart';
import 'protocol.dart';
import 'restart_handoff.dart';
import 'session_projection.dart';
import 'gestures.dart' show GestureMoments;
import 'timing.dart';
import 'watch.dart' show WatchedMoments;

final class MomentsOptions {
  const MomentsOptions({
    this.mapFile,
    this.manifestFile,
    this.directory,
    this.sessionFile,
    this.materialization,
    this.resumeOnOpen = true,
    this.restartTimeout,
    this.executor,
    this.recipeRef,
    this.openName,
    this.initialName,
    this.fresh = false,
    this.prepare,
    this.afterPreparedOpen,
    this.onRuntimeClaim,
  });

  final String? mapFile;
  final String? manifestFile;
  final String? directory;
  final String? sessionFile;
  final Map<String, Object?>? materialization;
  final bool resumeOnOpen;
  final Duration? restartTimeout;
  final String? executor;
  final String? recipeRef;
  final String? openName;
  final String? initialName;
  final bool fresh;
  final Future<void> Function(String name)? prepare;
  final Future<void> Function(String name)? afterPreparedOpen;
  final void Function(String client)? onRuntimeClaim;

  MomentsOptions copyWith({void Function(String client)? onRuntimeClaim}) => MomentsOptions(
    mapFile: mapFile,
    manifestFile: manifestFile,
    directory: directory,
    sessionFile: sessionFile,
    materialization: materialization,
    resumeOnOpen: resumeOnOpen,
    restartTimeout: restartTimeout,
    executor: executor,
    recipeRef: recipeRef,
    openName: openName,
    initialName: initialName,
    fresh: fresh,
    prepare: prepare,
    afterPreparedOpen: afterPreparedOpen,
    onRuntimeClaim: onRuntimeClaim ?? this.onRuntimeClaim,
  );
}

final class _Frame {
  _Frame({
    required this.id,
    required this.client,
    required this.revision,
    required this.capture,
    required this.guard,
    required this.codeHash,
  });
  final String id;
  final String? client;
  final String revision;
  final bool capture;
  final void Function() guard;
  final String codeHash;
  Map<String, Object?>? observed;
  int? sequence;
}

/// The declared Moments of one app as the runtime sees them: the active
/// Moment, its saved projection, and what the Flutter runtime last reported.
/// Serves `/moments/*` for the bridge.
final class Moments implements WatchedMoments, GestureMoments {
  Moments._(this.project, this._options, this._contract, this._file, this._sources);

  static Moments? create(String project, [MomentsOptions options = const MomentsOptions()]) {
    final mapFile = options.mapFile ?? p.join(project, 'MOMENTS.md');
    if (options.manifestFile == null && !File(mapFile).existsSync()) return null;
    final directory = options.directory ?? p.join(project, 'moments');
    final file = options.sessionFile ?? p.join(directory, '.session.json');
    final contract = options.manifestFile != null
        ? readManifest(options.manifestFile!)
        : (jsonDecode(File(p.join(directory, 'contract.json')).readAsStringSync()) as Map).cast<String, Object?>();
    final moments =
        Moments._(
            project,
            options,
            contract,
            file,
            DartSources.watched(project, ((contract['watch'] as List?) ?? const []).cast<String>()),
          )
          .._mapFile = mapFile
          .._directory = directory;
    moments._init();
    return moments;
  }

  final String project;
  final MomentsOptions _options;
  final Map<String, Object?> _contract;
  final String _file;
  final DartSources _sources;
  late final String _mapFile, _directory;
  Map<String, Object?>? _materialization;
  late final String _launchResolution;
  late String _appliedCodeHash;
  final _waiters = <HttpResponse>{};
  String _revision = uuidV4();
  late Map<String, Map<String, Object?>> _states;
  Map<String, Object?>? _state;
  Map<String, Object?>? _observed;
  var _observation = 0;
  var _nextObservation = Completer<void>();
  String? _activeClient;
  bool _supportsFrame = false, _supportsCaptureFrame = false;
  _Frame? _frame;
  Map<String, Object?>? _blocker;
  int _blockerSequence = 0, _lastCaptureSequence = 0;
  double? _moveStarted;
  bool _preparing = false, _opening = false;
  late final RestartHandoff _restart;

  void _init() {
    final materialization = _options.materialization;
    if (materialization != null) {
      final scene = (_contract['moments'] as Map?)?[materialization['moment']] as Map?;
      if (materialization.keys.any((key) => !const ['instanceId', 'moment', 'from', 'manifest'].contains(key)) ||
          _options.manifestFile == null ||
          scene == null ||
          materialization['manifest'] != _contract['recipeHash'] ||
          !RegExp(
            r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$',
          ).hasMatch('${materialization['instanceId'] ?? ''}') ||
          ![scene['from'], materialization['moment']].contains(materialization['from']) ||
          _options.openName != null ||
          _options.initialName != null) {
        throw const MomentsError('Invalid materialized actor context');
      }
      _materialization = {...materialization};
    }
    final launch = _sources.snapshot();
    _launchResolution = launch['resolutionDigest']! as String;
    _appliedCodeHash = launch['digest']! as String;
    final saved = readSavedMoments(_file, _contract);
    _states = saved.states;
    _state = saved.state;
    _restart = RestartHandoff(
      timeout: _options.restartTimeout,
      notify: () {
        for (final waiter in [..._waiters]) {
          reply(waiter, 200, _transportSnapshot(_activeClient));
        }
        _waiters.clear();
      },
    );
    if (_materialization != null) {
      final from = _materialization!['from'];
      if (_state == null || (from != null && _state!['name'] != from)) {
        throw const MomentsError('Materialized actor checkpoint does not match its source Moment');
      }
      // Name the intended transition, retaining the parent projection. This is
      // not a claim that the target transition or its criteria have completed.
      _persist({
        ..._state!,
        'name': _materialization!['moment'],
        'recipeHash': _materialization!['manifest'],
        'projection': _validate(_state!['projection'], restoring: true),
      });
    }
    if (_options.openName != null) {
      _move(_options.openName!, reset: _options.fresh);
    } else if (_state == null && _options.initialName != null) {
      _move(_options.initialName!);
    }
    if (_state != null) {
      _state = {..._state!, 'projection': _resume(_state!, _evaluate(_state!['name']! as String))};
    }
  }

  Map<String, Object?> _validate(Object? projection, {bool restoring = false}) =>
      validateProjection(_contract, projection, restoring: restoring);

  Map<String, Object?> _resume(Map<String, Object?> remembered, Map<String, Object?> recipe) =>
      resumeProjection(_contract, remembered, recipe);

  ({Manifest? manifest, MomentMap? map, Map<String, Object?>? recipes, String recipeHash}) _catalog() {
    if (_options.manifestFile != null) {
      final manifest = readManifest(_options.manifestFile!);
      if (_materialization != null && manifest['recipeHash'] != _materialization!['manifest']) {
        throw const MomentsError('Materialized declaration changed; use a new instance');
      }
      if (!jsonEqual(manifest['screens'], _contract['screens']) ||
          !jsonEqual(manifest['properties'], _contract['properties']) ||
          !jsonEqual(manifest['watch'], _contract['watch'])) {
        throw const MomentsError('Moment contract changed; restart the launcher to load it');
      }
      return (manifest: manifest, map: null, recipes: null, recipeHash: manifest['recipeHash']! as String);
    }
    final text = File(_mapFile).readAsStringSync();
    final map = parseMap(text);
    if (map.meta['moments'] != '0.1') throw const MomentsError('Unsupported Moments version');
    final recipes = File(p.join(_directory, 'recipes.json')).readAsStringSync();
    return (
      manifest: null,
      map: map,
      recipes: (jsonDecode(recipes) as Map).cast(),
      recipeHash: hashText(text + recipes),
    );
  }

  Map<String, Object?> _evaluate(String name) {
    final (:manifest, :map, :recipes, :recipeHash) = _catalog();
    if (manifest != null) {
      final moments = (manifest['moments']! as Map).cast<String, Object?>();
      if (!moments.containsKey(name)) throw MomentsError('Unknown moment: $name');
      if (_materialization != null) {
        if (name != _materialization!['moment']) {
          throw const MomentsError('Moment does not belong to this materialized actor');
        }
      } else {
        assertMaterializable((moments[name]! as Map).cast());
      }
      return {
        'name': name,
        'recipeHash': recipeHash,
        'projection': _validate((moments[name]! as Map)['projection'], restoring: true),
      };
    }
    final seen = <String>{}, chain = <String>[];
    for (String? current = name; current != null; current = map.states[current]?.from) {
      if (!map!.states.containsKey(current) || !seen.add(current)) {
        throw const MomentsError('Unknown moment or parent cycle');
      }
      chain.insert(0, current);
    }
    var projection = <String, Object?>{};
    for (final item in chain) {
      final entry = map!.states[item]!;
      if (entry.run?.executor != (_options.executor ?? 'flutter-draft') ||
          entry.run?.ref != '${_options.recipeRef ?? 'moments/recipes.json'}#$item' ||
          entry.expires != null ||
          entry.memory) {
        throw const MomentsError('This adapter supports declarative flutter-draft recipes only');
      }
      final recipe = (recipes![item] as Map?)?.cast<String, Object?>();
      if (recipe == null) throw MomentsError('Missing recipe: $item');
      projection = _contract['properties'] != null
          ? {...projection, ...recipe}
          : {
              ...projection,
              ...recipe,
              'fields': {
                ...?(projection['fields'] as Map?)?.cast<String, Object?>(),
                ...?(recipe['fields'] as Map?)?.cast<String, Object?>(),
              },
            };
    }
    return {'name': name, 'recipeHash': recipeHash, 'projection': _validate(projection)};
  }

  String _codeHash() => _sources.snapshot()['digest']! as String;

  Map<String, Object?> _dartState() {
    final current = _sources.snapshot();
    return {
      'version': 1,
      'current': current['digest'],
      'applied': _appliedCodeHash,
      'resolutionChanged': current['resolutionDigest'] != _launchResolution,
      'fileCount': current['fileCount'],
      'packageCount': current['packageCount'],
    };
  }

  Map<String, Object?> _snapshot() => {
    'revision': _revision,
    'state': _state,
    if (_materialization != null) 'materialization': {..._materialization!},
  };

  Map<String, Object?>? _frameControl(String? client) {
    final frame = _frame;
    if (frame == null || frame.client != client || frame.observed != null) return null;
    return {'id': frame.id, 'revision': frame.revision, if (frame.capture) 'capture': true};
  }

  Map<String, Object?> _transportSnapshot(String? client) => {
    ..._snapshot(),
    'runtimeBlocker': 1,
    'restart': _restart.control(client),
    'frame': _frameControl(client),
  };

  void _persist(Map<String, Object?> next) {
    final projection = (next['projection']! as Map).cast<String, Object?>();
    next = {...next, 'projection': restorableProjection(projection, propertiesFor(_contract, projection['route']))};
    final states = {..._states, next['name']! as String: next};
    final session = {'version': 2, 'active': next['name'], 'states': states};
    final handle = openPrivate('$_file.tmp');
    try {
      handle.writeStringSync('${const JsonEncoder.withIndent('  ').convert(session)}\n');
    } finally {
      handle.closeSync();
    }
    File('$_file.tmp').renameSync(_file);
    _state = next;
    _states = states;
  }

  void _notifyWaiters() {
    for (final waiter in [..._waiters]) {
      reply(waiter, 200, _transportSnapshot(_activeClient));
    }
    _waiters.clear();
  }

  Map<String, Object?> _move(String name, {bool reset = false}) {
    if (_materialization != null) {
      throw const MomentsError('Materialized actors must be opened or reset through their coordinator');
    }
    if (_preparing) throw const MomentsError('Backend preparation is in progress');
    final recipe = _evaluate(name); // Removed/unknown catalog names cannot be revived from disk.
    final remembered = !reset && _options.resumeOnOpen ? _states[name] : null;
    final next = remembered != null
        ? {...remembered, 'projection': _resume(remembered, recipe)}
        : {...recipe, 'codeHash': _codeHash()};
    _moveStarted = nowMs();
    _persist(next);
    _revision = uuidV4();
    _setObserved(null);
    _lastCaptureSequence = 0;
    _frame = null;
    _blocker = null;
    _blockerSequence = 0;
    for (final waiter in [..._waiters]) {
      reply(waiter, 200, _snapshot());
    }
    _waiters.clear();
    return _snapshot();
  }

  Future<Map<String, Object?>> _openPrepared(String name, {bool fresh = false, bool prepare = true}) async {
    if (_opening) throw const MomentsError('A prepared open is already running');
    _opening = true;
    try {
      return await _prepareAndMove(name, fresh: fresh, prepare: prepare);
    } finally {
      _opening = false;
    }
  }

  Future<Map<String, Object?>> _prepareAndMove(String name, {bool fresh = false, bool prepare = true}) async {
    if (_materialization != null) {
      throw const MomentsError('Materialized actors cannot prepare or open independent recipes');
    }
    if (_preparing) throw const MomentsError('Backend preparation is in progress');
    final recipe = _evaluate(name);
    // Check the destination's retained draft before any backend effect. It may
    // be inactive and therefore not validated by startup. Explicit fresh intent
    // selects the current declaration instead of attempting a migration.
    final remembered = !fresh && _options.resumeOnOpen ? _states[name] : null;
    if (remembered != null) _resume(remembered, recipe);
    final declared = ((_catalog().manifest?['moments'] as Map?)?[name] as Map?)?['backend'];
    if (prepare && declared != null) {
      final run = _options.prepare;
      if (run == null) throw const MomentsError('No backend recipe executor is configured');
      _preparing = true;
      try {
        await run(name);
        if (_evaluate(name)['recipeHash'] != recipe['recipeHash']) {
          throw const MomentsError(
            'Declaration changed during backend preparation; effects may have occurred. Inspect backend state before choosing a new preparation.',
          );
        }
      } finally {
        _preparing = false;
      }
    }
    _move(name, reset: fresh);
    if (prepare && declared != null) await _options.afterPreparedOpen?.call(name);
    return _snapshot();
  }

  List<String> get watchPaths => ((_contract['watch'] as List?) ?? const []).cast<String>();
  Map<String, Object?> sourceSnapshot({bool fresh = false}) => _sources.snapshot(fresh: fresh);
  List<String> get sourceLibraries {
    try {
      return [for (final package in _sources.localPackages()) package.library];
    } on MomentsError {
      return const [];
    }
  }

  @override
  String sourceFingerprint() => _codeHash();

  @override
  Map<String, Object?> inspect() {
    final current = _catalog();
    final manifestMoments = (current.manifest?['moments'] as Map?)?.cast<String, Object?>();
    final names = manifestMoments != null ? manifestMoments.keys.toList() : current.map!.order;
    Object? codeChanged = false;
    String? sourceIssue;
    Map<String, Object?>? dart;
    try {
      dart = _dartState();
      codeChanged = _state != null ? dart['applied'] != dart['current'] || dart['resolutionChanged'] == true : false;
    } on Object {
      codeChanged = null;
      sourceIssue = 'A watched source is unavailable';
    }
    return {
      ..._snapshot(),
      'observed': _observed,
      'blocker': _blocker,
      'preparing': _preparing,
      'opening': _opening,
      'backend': (manifestMoments?[_state?['name']] as Map?)?['backend'],
      'catalog': [
        for (final name in names) {'name': name, 'saved': _states.containsKey(name), 'active': _state?['name'] == name},
      ],
      'watch': _contract['watch'],
      'declaration': _options.manifestFile ?? _mapFile,
      'codeChanged': codeChanged,
      'sourceIssue': ?sourceIssue,
      'dart': ?dart,
      'recipeChanged': _state != null ? _state!['recipeHash'] != current.recipeHash : false,
    };
  }

  void validateName(Object? name) {
    if (name is! String) throw const MomentsError('Named Moment required');
    _evaluate(name);
  }

  @override
  bool inputAllowed(String reference, String target, [String kind = 'fill']) {
    final steps =
        ((((_catalog().manifest?['moments'] as Map?)?[_state?['name']]) as Map?)?['steps'] as List?) ?? const [];
    return steps.cast<Map>().any(
      (step) => step['kind'] == kind && step['inputRef'] == reference && step['target'] == target,
    );
  }

  Map<String, Object?> open(String name, {bool fresh = false}) => _move(name, reset: fresh);
  @override
  Future<void Function()> prepareRestart() => _restart.prepare(_activeClient);

  // Startup scheduling only: an observation is not a liveness/proof receipt.
  // Claims and route revisions must be observed before automatic compilation.
  @override
  bool hasRuntimeClaim() => _activeClient != null;
  @override
  bool hasObservedRuntime() =>
      _activeClient != null && _observed?['client'] == _activeClient && _observed?['revision'] == _revision;
  bool hasPendingCapture() => _frame?.capture == true && _frame?.observed == null;
  @override
  bool canReload() => _supportsFrame && _activeClient != null && _observed?['revision'] == _revision;

  @override
  String requestFrame(Map<String, Object?> checkpoint, {bool capture = false, void Function()? guard}) {
    if (_frame != null ||
        _activeClient != checkpoint['client'] ||
        _revision != checkpoint['revision'] ||
        !_supportsFrame) {
      throw const MomentsError('Moment runtime changed before post-compile observation; refresh --restart');
    }
    if (capture && !_supportsCaptureFrame) {
      throw const MomentsError('Runtime does not support captured frames; restart Flutter');
    }
    final check = guard ?? () {};
    check();
    final frame = _Frame(
      id: uuidV4(),
      client: _activeClient,
      revision: _revision,
      capture: capture,
      guard: check,
      codeHash: checkpoint['codeHash']! as String,
    );
    _frame = frame;
    _notifyWaiters();
    return frame.id;
  }

  @override
  Map<String, Object?>? frameAfter(String id) =>
      _frame?.id == id && _frame?.observed != null ? {..._frame!.observed!, 'name': _state!['name']} : null;

  @override
  Map<String, Object?>? blockerAfter(Map<String, Object?> checkpoint, {bool fullRestart = false, String? frameId}) {
    final blocker = _blocker;
    if (blocker == null || blocker['revision'] != checkpoint['revision'] || blocker['client'] != _activeClient) {
      return null;
    }
    final matches = fullRestart
        ? blocker['client'] != checkpoint['client']
        : blocker['frameId'] == frameId && frameId != null;
    return matches ? {...blocker} : null;
  }

  @override
  void cancelFrame(String id) {
    if (_frame?.id == id) _frame = null;
  }

  Map<String, Object?>? capturedFrameAfter(String id) {
    final frame = _frame;
    if (frame?.id != id ||
        frame!.capture != true ||
        frame.observed == null ||
        frame.sequence != _lastCaptureSequence ||
        !identical(_observed, frame.observed)) {
      return null;
    }
    return {
      'id': id,
      'revision': _revision,
      'client': _activeClient,
      'sequence': frame.sequence,
      'name': _state!['name'],
      'reportedAt': _observed!['reportedAt'],
      'scope':
          'Declared UI projection captured after a fresh ready frame; not business verification or global quiescence',
    };
  }

  @override
  Map<String, Object?> checkpoint() {
    final current = _sources.snapshot();
    if (current['resolutionDigest'] != _launchResolution) {
      throw const MomentsError(
        'Pub manifests or resolution changed; run flutter pub get and restart the Moments launcher',
      );
    }
    return {'client': _activeClient, 'revision': _revision, 'codeHash': current['digest']};
  }

  @override
  Map<String, Object?>? restorationAfter(Map<String, Object?> checkpoint) {
    final observed = _observed;
    if (observed == null ||
        _revision != checkpoint['revision'] ||
        observed['client'] == checkpoint['client'] ||
        observed['revision'] != _revision) {
      return null;
    }
    return {...observed, 'name': _state!['name']};
  }

  @override
  void markCodeApplied(Map<String, Object?> checkpoint) {
    if (_revision != checkpoint['revision'] || _sources.snapshot(reuse: false)['digest'] != checkpoint['codeHash']) {
      throw const MomentsError('Moment or source changed during refresh; awaiting the next refresh');
    }
    _appliedCodeHash = checkpoint['codeHash']! as String;
    if (_state != null) _persist({..._state!, 'codeHash': checkpoint['codeHash']});
  }

  static bool _safeInt(Object? value) => value is int;

  Future<bool> handle(HttpRequest request, Uri url, Body body) async {
    if (!url.path.startsWith('/moments/')) return false;
    final response = request.response;
    final op = url.path.substring('/moments/'.length);
    final method = request.method;
    if (method == 'GET' && op == 'changes') {
      final client = url.queryParameters['client'];
      if (client == null || client.isEmpty || client.length > 100) throw const MomentsError('Client id required');
      // A newly started runtime takes ownership. Old tabs cannot overwrite it.
      if (url.queryParameters['since'] == null || url.queryParameters['since']!.isEmpty) {
        for (final waiting in [..._waiters]) {
          reply(waiting, 409, {'error': 'Another runtime owns the draft session'});
        }
        _waiters.clear();
        _options.onRuntimeClaim?.call(client);
        _restart.claim(client);
        _activeClient = client;
        _setObserved(null);
        _lastCaptureSequence = 0;
        _frame = null;
        _blocker = null;
        _blockerSequence = 0;
        _supportsFrame = url.queryParameters['frame'] == '1';
        _supportsCaptureFrame = url.queryParameters['captureFrame'] == '1';
      }
      if (_activeClient != client) {
        reply(response, 409, {'error': 'Another runtime owns the draft session'});
        return true;
      }
      if (url.queryParameters['since'] != _revision ||
          _restart.control(client) != null ||
          _frameControl(client) != null) {
        reply(response, 200, _transportSnapshot(client));
      } else {
        _waiters.add(response);
        final timer = Timer(const Duration(seconds: 20), () {
          _waiters.remove(response);
          reply(response, 204);
        });
        trackClose(response, () {
          timer.cancel();
          _waiters.remove(response);
        });
      }
    } else if (method == 'POST' && op == 'blocker') {
      final data = await body();
      if (data.keys.any((key) => !const ['revision', 'client', 'sequence', 'reason', 'frameId'].contains(key)) ||
          ![null, 'authentication-required', 'session-unavailable'].contains(data['reason']) ||
          !_safeInt(data['sequence']) ||
          (data['sequence']! as int) < 1) {
        throw const MomentsError('Invalid runtime blocker');
      }
      final frame = _frame;
      if (_state == null ||
          data['revision'] != _revision ||
          data['client'] != _activeClient ||
          (data['sequence']! as int) <= _blockerSequence ||
          (data['frameId'] != null &&
              (frame == null ||
                  frame.id != data['frameId'] ||
                  frame.client != _activeClient ||
                  frame.revision != _revision))) {
        reply(response, 409, {'accepted': false});
        return true;
      }
      _blockerSequence = data['sequence']! as int;
      _blocker = data['reason'] == null
          ? null
          : {
              'reason': data['reason'],
              'revision': _revision,
              'client': _activeClient,
              'sequence': data['sequence'],
              if (data['frameId'] != null) 'frameId': data['frameId'],
              'reportedAt': DateTime.now().toUtc().toIso8601String(),
            };
      // Diagnostic only. Never persist it or replace a saved draft with the
      // login screen; an old observation must not certify a blocked runtime.
      if (_blocker != null) {
        _setObserved(null);
        frame?.observed = null;
      }
      reply(response, 200, {'accepted': true});
    } else if (method == 'POST' && op == 'frame-ack') {
      final data = await body();
      final frame = _frame;
      if (_blocker != null ||
          frame == null ||
          frame.observed != null ||
          data['id'] != frame.id ||
          data['client'] != _activeClient ||
          frame.client != _activeClient ||
          data['revision'] != _revision ||
          frame.revision != _revision ||
          _state == null) {
        reply(response, 409, {'accepted': false});
        return true;
      }
      final projection = _validate(data['projection']);
      if (frame.capture) {
        frame.guard();
        if (_codeHash() != frame.codeHash ||
            data['capture'] != true ||
            !_safeInt(data['sequence']) ||
            (data['sequence']! as int) <= _lastCaptureSequence) {
          reply(response, 409, {'accepted': false});
          return true;
        }
        _persist({..._state!, 'projection': projection});
        _lastCaptureSequence = data['sequence']! as int;
        frame.sequence = data['sequence']! as int;
      }
      _setObserved({
        'revision': _revision,
        'client': _activeClient,
        'projection': projection,
        'reportedAt': DateTime.now().toUtc().toIso8601String(),
        'timing': null,
        if (frame.capture) 'captureSequence': frame.sequence,
      });
      frame.observed = _observed;
      reply(response, 200, {'accepted': true});
    } else if (method == 'POST' && op == 'restart-ack') {
      final data = await body();
      final accepted = data['client'] == _activeClient && _restart.acknowledge(data);
      reply(response, accepted ? 200 : 409, {'accepted': accepted});
    } else if (method == 'GET' && op == 'ls') {
      final (:manifest, :map, recipes: _, recipeHash: _) = _catalog();
      final entries = manifest != null
          ? [
              for (final MapEntry(key: name, value: scene) in (manifest['moments']! as Map).entries)
                {'name': name, 'from': (scene as Map)['from'], 'description': scene['description']},
            ]
          : [
              for (final name in map!.order)
                {'name': name, 'from': map.states[name]!.from, 'description': map.states[name]!.describe},
            ];
      reply(response, 200, [
        for (final entry in entries)
          {...entry, 'saved': _states.containsKey(entry['name']), 'active': _state?['name'] == entry['name']},
      ]);
    } else if (method == 'GET' && op == 'look') {
      // `after` + `wait` hold the answer until the next UI report, so a
      // journey wakes on the report instead of sleeping between reads.
      final after = int.tryParse(url.queryParameters['after'] ?? '');
      final wait = (int.tryParse(url.queryParameters['wait'] ?? '') ?? 0).clamp(0, 2000);
      if (after != null && after == _observation && wait > 0) {
        await _nextObservation.future.timeout(Duration(milliseconds: wait), onTimeout: () {});
      }
      final dart = _dartState();
      reply(response, 200, {
        ..._snapshot(),
        'observation': _observation,
        'observed': _observed,
        'blocker': _blocker,
        'dart': dart,
        'status': _state == null
            ? 'idle'
            : _blocker?['revision'] == _revision
            ? 'blocked'
            : _observed?['revision'] == _revision
            ? 'last-observed'
            : 'awaiting-runtime',
        'codeChanged': _state != null ? dart['applied'] != dart['current'] || dart['resolutionChanged'] == true : false,
        'recipeChanged': _state != null ? _state!['recipeHash'] != _catalog().recipeHash : false,
      });
    } else if (method == 'POST' && op == 'open') {
      final data = await body();
      if (data['fresh'] != null && data['fresh'] is! bool) throw const MomentsError('fresh must be a boolean');
      if (data['prepare'] != null && data['prepare'] is! bool) throw const MomentsError('prepare must be a boolean');
      final name = data['name'];
      if (name is! String) throw const MomentsError('Named Moment required');
      reply(
        response,
        200,
        await _openPrepared(name, fresh: data['fresh'] as bool? ?? false, prepare: data['prepare'] as bool? ?? true),
      );
    } else if (method == 'POST' && op == 'reset') {
      if (_state == null) throw const MomentsError('No moment is open');
      reply(response, 200, _move(_state!['name']! as String, reset: true));
    } else if (method == 'POST' && (op == 'capture' || op == 'observe')) {
      final data = await body();
      if (_blocker != null || data['revision'] != _revision || data['client'] != _activeClient || _state == null) {
        reply(response, 409, {'error': 'Stale, blocked or inactive runtime'});
        return true;
      }
      final projection = _validate(data['projection']);
      if (op == 'capture') {
        if (_preparing) throw const MomentsError('Backend preparation is in progress');
        if (!_safeInt(data['sequence']) || (data['sequence']! as int) <= _lastCaptureSequence) {
          reply(response, 409, {'error': 'Stale capture sequence'});
          return true;
        }
        _persist({..._state!, 'projection': projection});
        _lastCaptureSequence = data['sequence']! as int;
      }
      final timing = sanitizeTiming(data['timing']) ?? _observed?['timing'];
      _setObserved({
        'revision': _revision,
        'client': _activeClient,
        'projection': projection,
        'timing': timing,
        'reportedAt': DateTime.now().toUtc().toIso8601String(),
        'openToObservedMs': _moveStarted == null ? null : nowMs() - _moveStarted!,
      });
      _moveStarted = null;
      reply(response, 200, {'saved': op == 'capture', 'observed': true});
    } else {
      reply(response, 404, {'error': 'Unknown Moments operation'});
    }
    return true;
  }

  void _setObserved(Map<String, Object?>? value) {
    _observed = value;
    _observation++;
    final reached = _nextObservation;
    _nextObservation = Completer<void>();
    reached.complete();
  }

  void close() {
    _frame = null;
    _restart.close();
    unawaited(_sources.close());
    for (final waiter in [..._waiters]) {
      reply(waiter, 503, {'error': 'Bridge stopped'});
    }
    _waiters.clear();
  }
}
