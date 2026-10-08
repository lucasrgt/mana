import 'dart:convert';
import 'dart:math' as math;

/// A latency/query profile from the same verified journey. Backend durations
/// may overlap (parallel requests, nested actions); never subtract or sum them
/// to claim CPU time, frontend time, or an additive end-to-end breakdown.
Map<String, Object?> journeyProfile(Map<String, Object?> report, {bool requiresBackend = false}) {
  final actions = report['actions'] as Map?;
  final receipts = ((actions?['receipts'] as List?) ?? const []).cast<Map>();
  final profiled = receipts.where((r) => r['version'] == 2).toList();
  Map profileOf(Map r) => r['profile'] as Map;
  Map databaseOf(Map r) => profileOf(r)['database'] as Map;
  final database = profiled.where((r) => databaseOf(r)['status'] == 'observed').toList();
  final groups = <String, Map<String, Object?>>{};
  for (final receipt in receipts) {
    for (final action in (receipt['actions'] as List).cast<Map>()) {
      final kind = action['kind'] ?? 'action';
      final key = jsonEncode([receipt['step'], action['resource'], action['action'], kind]);
      final group = groups.putIfAbsent(
        key,
        () => {
          'step': receipt['step'],
          'resource': action['resource'],
          'action': action['action'],
          'kind': kind,
          'spans': 0,
          'timedSpans': 0,
          'sumInclusiveMs': 0,
          'maxInclusiveMs': 0,
        },
      );
      group['spans'] = (group['spans']! as int) + 1;
      if (action['durationUs'] case final num micros) {
        group['timedSpans'] = (group['timedSpans']! as int) + 1;
        group['sumInclusiveMs'] = (group['sumInclusiveMs']! as num) + micros / 1000;
        group['maxInclusiveMs'] = math.max(group['maxInclusiveMs']! as num, micros / 1000);
      }
    }
  }
  final incomplete =
      receipts.length != profiled.length ||
      actions?['overflow'] == true ||
      receipts.any((r) => r['truncated'] == true) ||
      (requiresBackend && (profiled.isEmpty || actions?['status'] != 'observed'));
  num sumDatabase(String key) => database.fold<num>(0, (n, r) => n + (databaseOf(r)['${key}Us'] as num) / 1000);
  final sortedGroups = groups.values.toList()
    ..sort((a, b) => ((b['sumInclusiveMs']! as num) - (a['sumInclusiveMs']! as num)).sign.toInt());
  return {
    'version': 1,
    'status': report['status'] == 'unavailable'
        ? 'unavailable'
        : incomplete
        ? 'partial'
        : 'measured',
    'journeyStatus': report['status'],
    'scope':
        'One instrumented local journey; request-context observations only. Not a CPU/heap profile, load benchmark or production latency claim.',
    'latency': {
      'totalMs': report['durationMs'],
      'phases': report['timings'] ?? <String, Object?>{},
      'steps': [
        for (final s in ((report['steps'] as List?) ?? const []).cast<Map>())
          {
            'name': s['name'],
            'status': s['status'],
            'dispatch': s['dispatch'],
            'durationMs': s['durationMs'],
            if (s['dispatchRequestMs'] != null) 'dispatchRequestMs': s['dispatchRequestMs'],
            if (s['postconditionMs'] != null) 'postconditionMs': s['postconditionMs'],
          },
      ],
    },
    'backend': {
      'status': profiled.isNotEmpty ? 'observed' : 'not-observed',
      'coverage': 'not-established',
      'requestsObserved': receipts.length,
      'requestsProfiled': profiled.length,
      'sumRequestMs': profiled.fold<num>(0, (n, r) => n + (profileOf(r)['requestDurationUs'] as num) / 1000),
      'maxRequestMs': profiled.fold<num>(0, (n, r) => math.max(n, (profileOf(r)['requestDurationUs'] as num) / 1000)),
      'database': {
        'status': database.isNotEmpty ? 'observed' : 'not-observed',
        'requestsObserved': database.length,
        'queries': database.isNotEmpty ? database.fold<num>(0, (n, r) => n + (databaseOf(r)['queries'] as num)) : null,
        for (final key in ['total', 'query', 'queue', 'decode'])
          'sum${key[0].toUpperCase()}${key.substring(1)}Ms': database.isNotEmpty ? sumDatabase(key) : null,
      },
      'actions': sortedGroups,
    },
    'limits': [
      'Preparation and criterion polling are engine overhead, not application latency.',
      'Action spans are inclusive and may nest; query durations and HTTP requests may overlap.',
      'Only gesture-originated requests returning receipts are observed. Detached jobs and unrelated processes are excluded.',
      'No database event observed is unknown, not zero queries. Truncation or old/missing receipts makes the profile partial.',
      'Debug instrumentation adds overhead. Functional success and performance evidence are separate.',
    ],
  };
}
