import 'configuration.dart';


import 'timing_visibility.dart'
    if (dart.library.js_interop) 'timing_visibility_web.dart';

enum MomentStage {
  preferences,
  developmentSession,
  bootstrapRequest,
  authentication,
  sessionBootstrap,
  screenData,
  restoreFields,
  restoreLayout,
}

enum MomentMark {
  main,
  runApp,
  firstFrame,
  momentReceived,
  screenReady,
  restoreScheduled,
  restoreStarted,
  observeSent,
}

/// Bounded, debug-only measurements. No payloads, routes or account data.
/// All timestamps use this runtime's monotonic clock, not the supervisor's.
abstract final class MomentTiming {
  static Stopwatch? _clock;
  static final _marks = <String, Object>{};
  static final _spans = <Map<String, Object>>[];

  static void start({bool enabled = momentsEnabled}) {
    _clock = momentsBuild && enabled ? (Stopwatch()..start()) : null;
    _marks.clear();
    _spans.clear();
    mark(MomentMark.main);
  }

  static double get _ms => _clock!.elapsedMicroseconds / 1000;

  static void mark(MomentMark mark) {
    if (_clock == null) return;
    _marks.putIfAbsent(mark.name, () => {'ms': _ms, ...timingVisibility()});
  }

  static Future<T> measure<T>(
    MomentStage stage,
    Future<T> Function() action,
  ) async {
    final clock = _clock;
    if (clock == null) return action();
    final start = _ms;
    var outcome = 'ok';
    try {
      return await action();
    } on Object {
      outcome = 'error';
      rethrow;
    } finally {
      if (identical(clock, _clock) && _spans.length < 32) {
        _spans.add({
          'stage': stage.name,
          'startMs': start,
          'durationMs': _ms - start,
          'outcome': outcome,
        });
      }
    }
  }

  static Map<String, Object>? snapshot() => _clock == null
      ? null
      : {
          'clock': 'dart-monotonic',
          'elapsedMs': _ms,
          'marks': Map<String, Object>.from(_marks),
          'spans': [for (final span in _spans) Map<String, Object>.from(span)],
        };
}
