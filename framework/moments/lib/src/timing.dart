const _stages = {
  'preferences',
  'developmentSession',
  'bootstrapRequest',
  'authentication',
  'sessionBootstrap',
  'screenData',
  'restoreFields',
  'restoreLayout',
};
const _marks = {
  'main',
  'runApp',
  'firstFrame',
  'momentReceived',
  'screenReady',
  'restoreScheduled',
  'restoreStarted',
  'observeSent',
};

bool _ms(Object? value) => value is num && value.isFinite && value >= 0 && value <= 86400000;

/// Advisory durations from one runtime clock. Never retain client-supplied
/// labels, field values or arbitrary metadata, and never use timing to
/// approve a proof.
Map<String, Object?>? sanitizeGestureTiming(Object? value) {
  if (value is! Map ||
      value['clock'] != 'dart-monotonic' ||
      !['frameMs', 'executeMs', 'totalMs'].every((key) => _ms(value[key]) && (value[key] as num) <= 60000) ||
      (value['frameMs'] as num) + (value['executeMs'] as num) > (value['totalMs'] as num) + 0.1) {
    return null;
  }
  return {
    'clock': 'dart-monotonic',
    'frameMs': value['frameMs'],
    'executeMs': value['executeMs'],
    'totalMs': value['totalMs'],
  };
}

/// Optional diagnostics must neither change a proof nor persist arbitrary data.
Map<String, Object?>? sanitizeTiming(Object? value) {
  if (value is! Map ||
      value['clock'] != 'dart-monotonic' ||
      !_ms(value['elapsedMs']) ||
      value['marks'] is! Map ||
      value['spans'] is! List ||
      (value['spans'] as List).length > 32) {
    return null;
  }
  final elapsed = value['elapsedMs'] as num;
  final selectedMarks = <String, Object?>{};
  for (final MapEntry(:key, value: mark) in (value['marks'] as Map).entries) {
    if (!_marks.contains(key) ||
        mark is! Map ||
        !_ms(mark['ms']) ||
        (mark['ms'] as num) > elapsed ||
        !const ['visible', 'hidden', 'native'].contains(mark['visibility']) ||
        (mark['focused'] != null && mark['focused'] is! bool)) {
      return null;
    }
    selectedMarks[key as String] = {
      'ms': mark['ms'],
      'visibility': mark['visibility'],
      if (mark['focused'] != null) 'focused': mark['focused'],
    };
  }
  final selectedSpans = <Map<String, Object?>>[];
  for (final span in value['spans'] as List) {
    if (span is! Map ||
        !_stages.contains(span['stage']) ||
        !_ms(span['startMs']) ||
        !_ms(span['durationMs']) ||
        (span['startMs'] as num) + (span['durationMs'] as num) > elapsed + 0.1 ||
        !const ['ok', 'error'].contains(span['outcome'])) {
      return null;
    }
    selectedSpans.add({
      'stage': span['stage'],
      'startMs': span['startMs'],
      'durationMs': span['durationMs'],
      'outcome': span['outcome'],
    });
  }
  return {'clock': 'dart-monotonic', 'elapsedMs': elapsed, 'marks': selectedMarks, 'spans': selectedSpans};
}
