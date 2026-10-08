import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'errors.dart';
import 'json.dart';

/// What the watcher needs from the Flutter launcher.
abstract interface class WatchedMachine {
  bool ready();
  Future<Object?> restart({bool fullRestart});
}

/// The backend services whose sources the watcher also follows.
abstract interface class WatchedBackend {
  String fingerprint();
  Future<void> ensure();
}

/// What the watcher needs from the Moments runtime.
abstract interface class WatchedMoments {
  /// The resolved Dart inventory; throws [MomentsError] when unavailable.
  String sourceFingerprint();
  bool hasRuntimeClaim();
  bool hasObservedRuntime();
  bool canReload();
  Map<String, Object?> checkpoint();
  Future<void Function()> prepareRestart();
  String requestFrame(Map<String, Object?> checkpoint);
  void cancelFrame(String id);
  Map<String, Object?>? blockerAfter(Map<String, Object?> checkpoint, {bool fullRestart, String? frameId});
  Map<String, Object?>? restorationAfter(Map<String, Object?> checkpoint);
  Map<String, Object?>? frameAfter(String id);
  void markCodeApplied(Map<String, Object?> checkpoint);
}

/// Resolved local Dart inventory plus explicitly watched files. Content
/// hashing also sees atomic saves. Backend services supply their own source
/// fingerprint; builds, credentials and generated outputs stay outside it.
final class MomentWatcher {
  MomentWatcher({
    required this.project,
    required this.paths,
    required this.machine,
    required this.moments,
    this.backend,
    this.enabled = true,
    Duration interval = const Duration(milliseconds: 150),
    this.debounce = const Duration(milliseconds: 350),
    this.restoreTimeout = const Duration(seconds: 15),
    bool Function()? automaticAllowed,
    void Function(String text)? log,
  }) : _automaticAllowed = automaticAllowed ?? (() => true),
       _log = log ?? print {
    _status = {'phase': 'starting', 'automatic': enabled, 'paths': paths};
    _lastSeen = _fingerprint();
    _appliedBackend = backend?.fingerprint();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  final String project;
  final List<String> paths;
  final WatchedMachine machine;
  final WatchedMoments moments;
  final WatchedBackend? backend;
  final bool enabled;
  final Duration debounce, restoreTimeout;
  final bool Function() _automaticAllowed;
  final void Function(String text) _log;
  late Map<String, Object?> _status;
  late String _lastSeen;
  String? _appliedBackend;
  late final Timer _timer;
  var _held = false, _closed = false, _busy = false, _dirty = false;
  var _changedAt = DateTime.fromMillisecondsSinceEpoch(0);
  var _sequence = 0;

  String _fingerprint() {
    String source;
    try {
      source = moments.sourceFingerprint();
    } on MomentsError {
      source = jsonEncode([
        for (final path in paths)
          [path, File(p.join(project, path)).existsSync() ? File(p.join(project, path)).readAsStringSync() : null],
      ]);
    }
    return hashText(source + (backend?.fingerprint() ?? ''));
  }

  void _publish(Map<String, Object?> next) {
    _status = {..._status, ...next};
    _log('Moments refresh: ${jsonEncode(_status)}');
  }

  Future<Map<String, Object?>> refresh({bool restart = false}) async {
    if (_closed) throw const MomentsError('Watcher stopped');
    if (_busy || _held) throw const MomentsError('A refresh or data preparation is already running');
    if (!machine.ready()) throw const MomentsError('Flutter is not ready');
    if (!moments.hasRuntimeClaim()) {
      _publish({'phase': 'waiting-runtime'});
      return {..._status, 'pending': _dirty};
    }
    _busy = true;
    _dirty = false;
    final started = nowMs();
    final id = ++_sequence;
    _publish({
      'id': id,
      'phase': 'compiling',
      'error': null,
      'blocker': null,
      'compileMs': null,
      'restoreMs': null,
      'totalMs': null,
      'prepareMs': null,
      'compilerMs': null,
      'runtime': null,
      'backendMs': null,
      'failureStage': null,
    });
    void Function()? resume;
    String? frameId;
    var failureStage = 'flutter';
    try {
      // A manual refresh also consumes saves that the polling timer has not
      // seen yet. Later edits still change this fingerprint and queue normally.
      _lastSeen = _fingerprint();
      final checkpoint = moments.checkpoint();
      final backendHash = backend?.fingerprint();
      final fullRestart = restart || backendHash != _appliedBackend || !moments.canReload();
      _publish({'strategy': fullRestart ? 'restart' : 'reload'});
      if (fullRestart) resume = await moments.prepareRestart();
      if (_closed) return {..._status};
      failureStage = 'backend';
      final backendStarted = nowMs();
      await backend?.ensure();
      _publish({'backendMs': backend != null ? nowMs() - backendStarted : 0});
      failureStage = 'flutter';
      if (_closed) return {..._status};
      final prepareMs = nowMs() - started;
      await machine.restart(fullRestart: fullRestart);
      if (_closed) return {..._status};
      final compileMs = nowMs() - started;
      _publish({
        'phase': 'restoring',
        'compileMs': compileMs,
        'prepareMs': prepareMs,
        'compilerMs': compileMs - prepareMs,
      });
      if (!fullRestart) frameId = moments.requestFrame(checkpoint);
      final deadline = DateTime.now().add(restoreTimeout);
      Map<String, Object?>? observed;
      while (!_closed && DateTime.now().isBefore(deadline)) {
        final blocker = moments.blockerAfter(checkpoint, fullRestart: fullRestart, frameId: frameId);
        if (blocker != null) {
          failureStage = 'runtime';
          _publish({'blocker': blocker});
          throw MomentsError(
            blocker['reason'] == 'authentication-required'
                ? 'Authentication is required to restore this Moment. Sign in through the app, then refresh; the saved draft was retained.'
                : 'The app could not verify its session. Restore session access, then refresh; the saved draft was retained.',
          );
        }
        observed = fullRestart ? moments.restorationAfter(checkpoint) : moments.frameAfter(frameId!);
        if (observed != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (_closed) return {..._status};
      if (observed == null) {
        throw MomentsError(
          fullRestart
              ? 'Code compiled, but no new Flutter runtime confirmed restoration. Open the app and run moment refresh.'
              : 'Code compiled, but no post-compile frame confirmed the current Moment. Inspect the app, then refresh --restart if needed.',
        );
      }
      moments.markCodeApplied(checkpoint);
      _appliedBackend = backendHash;
      final totalMs = nowMs() - started;
      _publish({
        'phase': 'ready',
        'moment': observed['name'],
        'runtime': observed['timing'],
        'compileMs': compileMs,
        'restoreMs': totalMs - compileMs,
        'totalMs': totalMs,
        'finishedAt': DateTime.now().toUtc().toIso8601String(),
      });
    } on Object catch (error) {
      if (!_closed) {
        _publish({
          'phase': 'error',
          'failureStage': failureStage,
          'error': error is MomentsError ? error.message : '$error',
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
        });
      }
    } finally {
      if (frameId != null) moments.cancelFrame(frameId);
      resume?.call();
      _busy = false;
    }
    return {..._status};
  }

  void _tick() {
    if (_closed) return;
    try {
      final hash = _fingerprint();
      if (hash != _lastSeen) {
        _lastSeen = hash;
        if (enabled) {
          _dirty = true;
          _changedAt = DateTime.now();
        }
      }
      if (const ['starting', 'waiting-runtime'].contains(_status['phase']) && machine.ready()) {
        final phase = moments.hasObservedRuntime() ? 'idle' : 'waiting-runtime';
        if (_status['phase'] != phase) _publish({'phase': phase});
      }
      if (_dirty &&
          !_busy &&
          !_held &&
          _automaticAllowed() &&
          machine.ready() &&
          moments.hasObservedRuntime() &&
          DateTime.now().difference(_changedAt) >= debounce) {
        unawaited(refresh());
      }
    } on Object catch (error) {
      final message = error is MomentsError ? error.message : '$error';
      if (_status['error'] != message) _publish({'phase': 'error', 'error': message});
    }
  }

  Map<String, Object?> status() => {..._status, 'pending': _dirty, 'held': _held};

  void Function() pause() {
    if (_closed || _busy || _held || !machine.ready()) {
      throw const MomentsError('Flutter is not ready or another operation is running');
    }
    _held = true;
    var released = false;
    return () {
      if (!released) {
        released = true;
        _held = false;
      }
    };
  }

  void close() {
    _closed = true;
    _timer.cancel();
  }
}
