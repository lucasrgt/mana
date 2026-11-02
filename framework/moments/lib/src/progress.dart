import 'dart:math';

import 'json.dart';

/// How long a journey waits for its criteria. A fixed budget fails a long
/// step on a loaded machine while the app is still working (a request queued
/// behind other workers' writes); this one lasts while the app shows
/// progress — a screen report that changed what it shows or offers, requests
/// in flight, a request finishing — and ends [idleMs] after the last sign of
/// it, or at [limitMs] whatever happens. An app that reports no activity
/// gets [idleMs] after its last changed report.
final class ProgressWait {
  ProgressWait({this.idleMs = 8000, this.limitMs = 30000, double? started}) : started = started ?? nowMs() {
    _last = this.started;
  }

  final int idleMs, limitMs;
  final double started;
  late double _last;
  var _samples = 0, _signs = 0;
  double _busyMs = 0;
  double? _sampledAt;
  var _busy = false, _reported = false;
  Object? _projection, _offered;
  int? _activity;

  /// Records one `look` answer; true when it showed progress.
  bool observe(Map<String, Object?> look) {
    final now = nowMs();
    if (_busy && _sampledAt != null) _busyMs += now - _sampledAt!;
    _sampledAt = now;
    final observed = look['observed'] as Map?, activity = look['activity'] as Map?;
    var progress =
        _samples > 0 &&
        (!deepEqual(observed?['projection'], _projection) || !deepEqual(observed?['offered'], _offered));
    _samples++;
    _projection = observed?['projection'];
    _offered = observed?['offered'];
    final inFlight = activity?['inFlight'], sequence = activity?['sequence'];
    _reported = _reported || inFlight is int;
    _busy = inFlight is int && inFlight > 0;
    if (_busy || (sequence is int && _activity != null && sequence != _activity)) progress = true;
    if (sequence is int) _activity = sequence;
    if (progress) {
      _last = now;
      _signs++;
    }
    return progress;
  }

  bool get expired => nowMs() >= min(_last + idleMs, started + limitMs);

  /// Why the wait ended without its criteria: `limit` or `idle`.
  String get reason => nowMs() >= started + limitMs ? 'limit' : 'idle';

  /// Where the wait's time went, for the receipt: durations on this
  /// process's monotonic clock, never criteria.
  Map<String, Object?> receipt() => {
    'idleBudgetMs': idleMs,
    'limitMs': limitMs,
    'samples': _samples,
    'progressSigns': _signs,
    'lastProgressMs': _last - started,
    'busyMs': _busyMs,
    'activityReported': _reported,
  };
}
