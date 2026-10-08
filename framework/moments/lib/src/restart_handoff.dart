import 'dart:async';

import 'package:mana/mana.dart' show uuidV4;

import 'errors.dart';

final class _Handoff {
  _Handoff(this.id, this.client);
  final String id;
  final String client;
  String phase = 'pause';
  Completer<void>? ready = Completer<void>();
  Timer? timer;
}

/// Ephemeral transport control. Never part of a Moment's saved projection.
final class RestartHandoff {
  RestartHandoff({required this.notify, Duration? timeout, this.leaseMs = 90000})
    : timeout = timeout ?? const Duration(milliseconds: 2500);

  final void Function() notify;
  final Duration timeout;
  final int leaseMs;
  _Handoff? _current;

  void _release(String id) {
    final current = _current;
    if (current?.id != id) return;
    current!.timer?.cancel();
    final ready = current.ready;
    if (ready != null && !ready.isCompleted) ready.completeError(const MomentsError('Restart preparation cancelled'));
    current
      ..ready = null
      ..phase = 'resume';
    notify();
  }

  Map<String, Object?>? control(String? client) {
    final current = _current;
    if (current?.client != client || current!.phase == 'paused') return null;
    return {'id': current.id, 'phase': current.phase, 'leaseMs': leaseMs};
  }

  Future<void Function()> prepare(String? client) async {
    if (client == null) throw const MomentsError('No Flutter runtime connected; open the app before restarting');
    if (_current != null) throw const MomentsError('Previous restart handoff has not been released');
    final handoff = _Handoff(uuidV4(), client);
    _current = handoff;
    handoff.timer = Timer(timeout, () {
      final ready = handoff.ready;
      if (ready != null && !ready.isCompleted) {
        ready.completeError(
          const MomentsError('Flutter did not prepare for restart; reopen the app with the current Moments runtime'),
        );
      }
      handoff.ready = null;
      _release(handoff.id);
    });
    final ready = handoff.ready!.future;
    notify();
    await ready;
    return () => _release(handoff.id);
  }

  bool acknowledge(Map<String, Object?> data) {
    final current = _current;
    if (current == null || current.id != data['id'] || current.client != data['client']) return false;
    if (data['phase'] == 'paused' && current.phase == 'pause') {
      current.timer?.cancel();
      current.phase = 'paused';
      final ready = current.ready;
      current.ready = null;
      if (ready != null && !ready.isCompleted) ready.complete();
      return true;
    }
    if (data['phase'] == 'resumed' && current.phase == 'resume') {
      _current = null;
      return true;
    }
    return false;
  }

  void claim(String client) {
    final current = _current;
    if (current == null || current.client == client) return;
    current.timer?.cancel();
    final ready = current.ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(const MomentsError('Flutter runtime changed during restart preparation'));
    }
    _current = null;
  }

  void close() {
    final current = _current;
    if (current == null) return;
    _release(current.id);
    _current = null;
  }
}
