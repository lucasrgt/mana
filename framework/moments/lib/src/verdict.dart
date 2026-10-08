/// AVP (Acceptance Verification Protocol) verdicts for Moment criteria.
///
/// A Moment's declared criteria are an off-catalog AVP specification (ADR
/// 0002): `moment-criteria`, decided by mechanical oracles on the UI and
/// backend observations. Unavailable evidence is `unresolved`, never `pass`.
library;

const avpProtocolVersion = '0.4.0';
const momentArchetype = 'moment-criteria';

String _status(Object? status) => switch (status) {
  'passed' => 'pass',
  'failed' => 'fail',
  'not-applicable' => 'not-applicable',
  _ => 'unresolved',
};

String? _failure(Map<String, Object?> check) {
  if (check['status'] != 'failed') return null;
  final field = check['field'];
  return field == null
      ? 'Criterion ${check['name']} did not hold'
      : '$field: expected ${check['expected']}, observed ${check['observed']}';
}

/// [checks] are the evaluated criteria of a report whose overall [status] is
/// `passed`, `failed` or `unavailable`. A run-level failure or missing
/// evidence that no criterion carries becomes its own result, so the verdict
/// can never be greener than the report.
Map<String, Object?> avpVerdict({
  required String subject,
  required String status,
  required List<Map<String, Object?>> checks,
  String? reason,
}) {
  final results = <Map<String, Object?>>[
    for (final check in checks)
      {
        'criterionId': check['name'],
        'status': _status(check['status']),
        'reason': ?(check['reason'] ?? _failure(check)),
        if (check.containsKey('expected') || check.containsKey('observed'))
          'evidence': {'field': ?check['field'], 'expected': ?check['expected'], 'observed': ?check['observed']},
      },
  ];
  final statuses = results.map((r) => r['status']).toSet();
  if (status == 'failed' && !statuses.contains('fail')) {
    results.add({'criterionId': 'moment-run', 'status': 'fail', 'reason': reason ?? 'The journey failed'});
  } else if (status != 'passed' && status != 'failed' && !statuses.contains('unresolved')) {
    results.add({
      'criterionId': 'moment-observation',
      'status': 'unresolved',
      'reason': reason ?? 'The Moment could not be observed',
    });
  }
  final passed = results.where((r) => r['status'] == 'pass').length;
  final failed = results.where((r) => r['status'] == 'fail').length;
  final unresolved = results.any((r) => r['status'] == 'unresolved');
  final applicable = passed + failed;
  return {
    'protocol': 'avp',
    'protocolVersion': avpProtocolVersion,
    'subject': subject,
    'archetype': momentArchetype,
    'results': results,
    'outcome': failed > 0
        ? 'fail'
        : unresolved || applicable == 0
        ? 'inconclusive'
        : 'pass',
    'acceptanceScore': applicable == 0 ? null : passed / applicable,
  };
}
