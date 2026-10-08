import 'dart:async';
import 'dart:convert';

import 'package:mana/mana.dart' show uuidV4;

import 'composition.dart' show Interruption;
import 'errors.dart';
import 'inspect.dart';
import 'json.dart';

/// Coordinates a disposable app recipe; business actions remain in the app.
final class RenewalCoordinator implements Renewal {
  RenewalCoordinator({
    required this.acquire,
    required this.prepare,
    required this.commit,
    required this.refresh,
    this.canRenewMoment,
    void Function(String text)? log,
  }) : _log = log ?? print;

  final void Function() Function(String name) acquire;
  final Future<Map<String, Object?>> Function(String name, Interruption signal) prepare;
  final void Function(Map<String, Object?> launch) commit;
  final Future<Map<String, Object?>?> Function(String name) refresh;
  final bool Function(String name)? canRenewMoment;
  final void Function(String text) _log;
  var _status = <String, Object?>{'phase': 'idle'};
  var _running = false, _closed = false;
  Interruption? _signal;

  void _publish(Map<String, Object?> next) {
    _status = {..._status, ...next};
    _log('Moments renew: ${jsonEncode(_status)}');
  }

  @override
  bool canRenew(String name) => canRenewMoment?.call(name) ?? true;

  @override
  Map<String, Object?> status() => {..._status};

  @override
  Map<String, Object?> start(Object? name) {
    if (_closed) throw const MomentsError('Launcher is stopping');
    if (_running) throw const MomentsError('A renewal is already running');
    if (name is! String) throw const MomentsError('Named Moment required');
    final release = acquire(name); // Validation and lock precede any domain write.
    _running = true;
    final started = nowMs();
    final signal = _signal = Interruption();
    _status = {'id': uuidV4(), 'name': name, 'phase': 'preparing', 'dataPrepared': false, 'error': null};
    _publish({});
    unawaited(() async {
      try {
        final launch = await prepare(name, signal);
        if (_closed) return;
        commit(launch); // The old launch remains authoritative until this succeeds.
        _publish({'phase': 'restoring', 'dataPrepared': true, 'prepareMs': nowMs() - started});
        release();
        final report = await refresh(name);
        if (_closed) return;
        if (report?['phase'] != 'ready') {
          throw const MomentsError(
            'Data prepared, but the screen did not confirm restoration. Use moment refresh; renewing again would create another reservation.',
          );
        }
        _publish({'phase': 'ready', 'totalMs': nowMs() - started});
      } on Object catch (error) {
        if (!_closed)
          _publish({
            'phase': 'error',
            'error': error is MomentsError ? error.message : '$error',
            'totalMs': nowMs() - started,
          });
      } finally {
        release();
        _running = false;
      }
    }());
    return {..._status};
  }

  void close() {
    _closed = true;
    _signal?.abort();
  }
}
