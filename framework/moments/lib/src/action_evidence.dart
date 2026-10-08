import 'errors.dart';

final _uuid = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
final _module = RegExp(r'^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$');

bool _uuidOk(Object? value) => value is String && _uuid.hasMatch(value);
bool _moduleOk(Object? value) => value is String && value.length <= 256 && _module.hasMatch(value);
bool _keys(Object? value, List<String> allowed) => value is Map && value.keys.every(allowed.contains);
bool _micros(Object? value) => value is int && value >= 0 && value <= 86400000000;

Never _invalid(String message) => throw MomentsError(message);

Map<String, Object?> _requestProfile(Object? value) {
  if (!_keys(value, const ['requestDurationUs', 'database']) || !_micros((value! as Map)['requestDurationUs'])) {
    _invalid('Invalid request profile');
  }
  final db = (value as Map)['database'];
  if (db is Map && db['status'] == 'not-observed' && _keys(db, const ['status'])) return value.cast();
  if (!_keys(db, const ['status', 'queries', 'totalUs', 'queryUs', 'queueUs', 'decodeUs']) ||
      (db as Map)['status'] != 'observed' ||
      db['queries'] is! int ||
      (db['queries'] as int) < 1 ||
      (db['queries'] as int) > 1000000 ||
      !const ['totalUs', 'queryUs', 'queueUs', 'decodeUs'].every((key) => _micros(db[key]))) {
    _invalid('Invalid request profile');
  }
  return value.cast();
}

/// Allowlist before retaining or writing any client-supplied payload.
Map<String, Object?> actionReceipt(Object? value) {
  final profiled = value is Map && (value['version'] == 2 || value['version'] == 3);
  final changed = value is Map && value['version'] == 3;
  if (!_keys(value, [
    'version',
    'gesture',
    'request',
    'truncated',
    'actions',
    'scope',
    'coverage',
    if (profiled) 'profile',
    if (changed) 'changes',
  ])) {
    _invalid('Invalid action evidence');
  }
  final receipt = (value! as Map).cast<String, Object?>();
  if (![1, 2, 3].contains(receipt['version']) ||
      !_uuidOk(receipt['gesture']) ||
      receipt['request'] is! String ||
      !RegExp(r'^[a-f0-9]{32}$').hasMatch(receipt['request']! as String) ||
      receipt['truncated'] is! bool ||
      receipt['scope'] != 'request-actions-only' ||
      receipt['coverage'] != 'not-established' ||
      receipt['actions'] is! List ||
      (receipt['actions']! as List).length > 16) {
    _invalid('Invalid action evidence');
  }
  final actions = [
    for (final action in receipt['actions']! as List)
      () {
        if (!_keys(action, [
          'resource',
          'action',
          'domain',
          'authorization_requested',
          'outcome',
          'kind',
          if (profiled) 'durationUs',
        ])) {
          _invalid('Invalid action evidence');
        }
        final a = (action as Map).cast<String, Object?>();
        if (!_moduleOk(a['resource']) ||
            a['action'] is! String ||
            !RegExp(r'^[a-z_][a-zA-Z0-9_?!]{0,127}$').hasMatch(a['action']! as String) ||
            (a['domain'] != null && !_moduleOk(a['domain'])) ||
            (a['authorization_requested'] != null && a['authorization_requested'] is! bool) ||
            (a['kind'] != null &&
                !const ['action', 'bulk_create', 'bulk_update', 'bulk_destroy'].contains(a['kind'])) ||
            !const ['span-finished', 'error-reported'].contains(a['outcome']) ||
            (a['durationUs'] != null && !_micros(a['durationUs']))) {
          _invalid('Invalid action evidence');
        }
        return {...a};
      }(),
  ];
  return {
    ...receipt,
    'actions': actions,
    if (profiled) 'profile': _requestProfile(receipt['profile']),
    if (changed) 'changes': _changes(receipt['changes']),
  };
}

/// Which records a request changed (field names only), as a history reported them.
List<Map<String, Object?>> _changes(Object? value) {
  if (value is! List || value.isEmpty || value.length > 16) _invalid('Invalid action evidence');
  return [
    for (final change in value)
      () {
        if (!_keys(change, const ['resource', 'subject', 'action', 'outcome', 'fields'])) {
          _invalid('Invalid action evidence');
        }
        final c = (change as Map).cast<String, Object?>();
        final fields = c['fields'];
        if (!_moduleOk(c['resource']) ||
            c['subject'] is! String ||
            (c['subject']! as String).isEmpty ||
            (c['subject']! as String).length > 64 ||
            c['action'] is! String ||
            !RegExp(r'^[a-z_][a-zA-Z0-9_?!]{0,127}$').hasMatch(c['action']! as String) ||
            !const ['done', 'failed'].contains(c['outcome']) ||
            fields is! List ||
            fields.length > 32 ||
            fields.any((f) => f is! String || !RegExp(r'^[a-z_][a-z0-9_]{0,63}$').hasMatch(f))) {
          _invalid('Invalid action evidence');
        }
        return {
          ...c,
          'fields': [...fields.cast<String>()],
        };
      }(),
  ];
}

Map<String, Object?> actionEvidence(Object? value, List<Map<String, Object?>> steps, String journeyId) {
  if (!_keys(value, const ['version', 'journeyId', 'receipts', 'overflow'])) {
    _invalid('Invalid journey action evidence');
  }
  final evidence = (value! as Map).cast<String, Object?>();
  if (evidence['version'] != 1 ||
      evidence['journeyId'] != journeyId ||
      !_uuidOk(journeyId) ||
      evidence['overflow'] is! bool ||
      evidence['receipts'] is! List ||
      (evidence['receipts']! as List).length > 256) {
    _invalid('Invalid journey action evidence');
  }
  final selected = {for (final step in steps) step['id']: step['name']}, seen = <Object?>{};
  final receipts = [
    for (final raw in evidence['receipts']! as List)
      () {
        final receipt = actionReceipt(raw);
        if (!selected.containsKey(receipt['gesture']) || !seen.add(receipt['request'])) {
          _invalid('Action evidence does not match this journey');
        }
        return {...receipt, 'step': selected[receipt['gesture']]};
      }(),
  ];
  return {
    'status': receipts.isNotEmpty ? 'observed' : 'not-observed',
    'coverage': 'not-established',
    'scope':
        'Gesture-originated HTTP receipts forwarded by the owned Flutter runtime; not a complete call graph, assertion coverage or deployment attestation',
    'overflow': evidence['overflow'],
    'receipts': receipts,
  };
}
