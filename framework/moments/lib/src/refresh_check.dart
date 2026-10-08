import 'dart:async';

import 'journey.dart' show Request;
import 'json.dart';

final class RefreshCheckError implements Exception {
  const RefreshCheckError(this.message, [this.status = 'unavailable']);
  final String message;
  final String status;

  @override
  String toString() => message;
}

const _waiting = 'Open the Flutter app first; pending edits will apply automatically after the Moment is observed.';

/// Reuses the supervisor's attempt identity, including an automatic refresh
/// already in flight. Never starts a second compiler or silently follows a
/// newer attempt.
Future<({int id, Map<String, Object?> snapshot})> refreshForCheck({
  required Request request,
  required String name,
  required Map<String, Object?> report,
  int timeout = 80000,
  int poll = 50,
  bool restart = false,
}) async {
  final before = await request('/moments/look');
  if ((before['state'] as Map?)?['name'] != name) {
    throw const RefreshCheckError('The active Moment changed before refresh');
  }
  var current = await request('/dev/status');
  if (current['phase'] == 'waiting-runtime') throw const RefreshCheckError(_waiting);
  if (current['held'] == true) {
    throw const RefreshCheckError('Backend preparation is running; check again when it finishes');
  }
  final joining = const ['compiling', 'restoring'].contains(current['phase']);
  if (joining && restart && current['strategy'] != 'restart') {
    throw const RefreshCheckError('A reload is running; wait for it before refresh --restart');
  }
  if (!joining) current = await request('/dev/refresh', restart ? {'restart': true} : <String, Object?>{});
  if (current['phase'] == 'waiting-runtime') throw const RefreshCheckError(_waiting);
  final id = current['id'];
  if (id is! int || id < 1 || !const ['compiling', 'restoring', 'ready'].contains(current['phase'])) {
    throw const RefreshCheckError('Supervisor did not identify an active refresh');
  }
  final deadline = nowMs() + timeout;
  final refresh = <String, Object?>{'id': id, 'mode': joining ? 'joined' : 'started'};
  report['refresh'] = refresh;
  while (true) {
    report['stage'] = current['phase'] == 'compiling' ? 'compile' : 'restore';
    refresh.addAll({
      'phase': current['phase'],
      'strategy': current['strategy'] ?? 'restart',
      'compileMs': current['compileMs'],
      'restoreMs': current['restoreMs'],
      'totalMs': current['totalMs'],
      'backendMs': current['backendMs'],
      'prepareMs': current['prepareMs'],
      'compilerMs': current['compilerMs'],
      'runtime': current['runtime'],
    });
    if (current['id'] != id || current['held'] == true) {
      throw const RefreshCheckError('Refresh was superseded or backend preparation started');
    }
    if (current['phase'] == 'error') {
      final blocker = (current['blocker'] as Map?)?['reason'];
      if (current['failureStage'] == 'runtime' &&
          const ['authentication-required', 'session-unavailable'].contains(blocker)) {
        report['stage'] = 'restore';
        refresh['blocker'] = blocker;
        throw RefreshCheckError(
          blocker == 'authentication-required'
              ? 'Authentication is required to restore this Moment. Sign in through the app, then refresh; the saved draft was retained.'
              : 'The app could not verify its session. Restore session access, then refresh; the saved draft was retained.',
        );
      }
      if (current['failureStage'] == 'backend') {
        report['stage'] = 'backend';
        throw const RefreshCheckError('Backend update failed; inspect moments status and the service log', 'failed');
      }
      final compiled = current['compileMs'] is num;
      report['stage'] = compiled ? 'restore' : 'compile';
      throw RefreshCheckError(
        compiled
            ? 'Dart compiled, but Flutter did not confirm restoration; inspect moment dev'
            : 'Flutter compilation/restart failed; inspect moment dev',
        compiled ? 'unavailable' : 'failed',
      );
    }
    if (current['phase'] == 'ready') break;
    if (!const ['compiling', 'restoring'].contains(current['phase'])) {
      throw const RefreshCheckError('Supervisor stopped before confirming restoration');
    }
    if (nowMs() >= deadline) {
      throw const RefreshCheckError(
        'Refresh deadline reached; the supervisor may still be running; inspect moment dev',
      );
    }
    await Future<void>.delayed(Duration(milliseconds: poll));
    current = await request('/dev/status');
  }
  if (current['pending'] == true || current['moment'] != name) {
    throw const RefreshCheckError('Another edit is pending or a different Moment was restored');
  }
  final after = await request('/moments/look');
  final state = after['state'] as Map?;
  if (after['revision'] != before['revision'] ||
      state?['name'] != name ||
      after['codeChanged'] != false ||
      (after['observed'] as Map?)?['revision'] != after['revision'] ||
      !deepEqual(state?['projection'], (before['state'] as Map)['projection'])) {
    throw const RefreshCheckError('Moment or saved state changed during refresh, or current code was not applied');
  }
  return (id: id, snapshot: after);
}
