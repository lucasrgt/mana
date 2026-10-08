import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'action_evidence.dart';
import 'errors.dart';

final _uuid = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
final _moment = RegExp(r'^[a-z][a-z0-9-]{0,127}$');
bool _uuidOk(Object? value) => value is String && _uuid.hasMatch(value);
bool _momentOk(Object? value) => value is String && _moment.hasMatch(value);

typedef ReviewInput = ({Object? value, String sha256});

ReviewInput _readJson(String file) {
  const limit = 8 * 1024 * 1024;
  try {
    if (FileSystemEntity.typeSync(file, followLinks: false) != FileSystemEntityType.file) throw const FormatException();
    final handle = File(file).openSync();
    try {
      final before = handle.lengthSync();
      if (before > limit) throw const FormatException();
      final bytes = handle.readSync(limit + 1);
      final modified = File(file).lastModifiedSync();
      if (bytes.length > limit ||
          bytes.length != before ||
          handle.lengthSync() != before ||
          File(file).lastModifiedSync() != modified) {
        throw const FormatException();
      }
      return (value: jsonDecode(utf8.decode(bytes)), sha256: sha256.convert(bytes).toString());
    } finally {
      handle.closeSync();
    }
  } on Object {
    throw const MomentsError('Review input must be a readable JSON file of at most 8 MiB');
  }
}

/// Historical positive observations only. Never shrinks candidates or resolves reviews.
Map<String, Object?> reviewEvidence(Object? plan, List<ReviewInput> reports) {
  if (plan is! Map ||
      plan['version'] != 1 ||
      plan['status'] != 'planned' ||
      plan['executed'] != false ||
      plan['verification'] != 'not-performed' ||
      plan['target'] is! Map ||
      plan['moments'] is! List ||
      (plan['moments'] as List).length > 20000 ||
      reports.length > 32) {
    throw const MomentsError('Invalid action review plan or evidence count');
  }
  final target = plan['target'] as Map;
  // Reuse the receipt boundary for resource/action identifiers, without executing anything.
  final identified =
      (actionReceipt({
                    'version': 1,
                    'gesture': '00000000-0000-0000-0000-000000000000',
                    'request': '0' * 32,
                    'truncated': false,
                    'scope': 'request-actions-only',
                    'coverage': 'not-established',
                    'actions': [
                      {'resource': target['resource'], 'action': target['action'], 'outcome': 'span-finished'},
                    ],
                  })['actions']!
                  as List)
              .first
          as Map;
  final candidates = <String>{};
  for (final item in plan['moments'] as List) {
    if (item is! Map ||
        !_momentOk(item['name']) ||
        item['coverage'] != 'unverified' ||
        candidates.contains(item['name'])) {
      throw const MomentsError('Invalid review candidates');
    }
    candidates.add(item['name'] as String);
  }
  final seen = <String, String>{}, observations = <Map<String, Object?>>[], inputs = <Map<String, Object?>>[];
  for (final (:value, :sha256) in reports) {
    final report = value;
    final operation = report is Map ? report['operation'] : null;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256) ||
        report is! Map ||
        report['version'] != 1 ||
        !_uuidOk(report['id']) ||
        !_momentOk(report['name']) ||
        !const ['journey', 'materialized-journey', 'navigation', 'materialized-navigation'].contains(operation) ||
        !const ['passed', 'captured', 'failed', 'unavailable'].contains(report['status']) ||
        (report['status'] == 'captured' && !(operation as String).endsWith('navigation')) ||
        (report['status'] == 'passed' && (operation as String).endsWith('navigation'))) {
      throw const MomentsError('Invalid journey report');
    }
    final id = report['id'] as String;
    if (seen.containsKey(id)) {
      if (seen[id] != sha256) throw const MomentsError('Conflicting reports for the same journey');
      continue;
    }
    seen[id] = sha256;
    final capture = report['actions'];
    final input = <String, Object?>{
      'report': id,
      'sha256': sha256,
      'moment': report['name'],
      'journeyStatus': report['status'],
      'capture': 'unavailable',
      'truncated': null,
      'matchingSpans': 0,
    };
    inputs.add(input);
    if (!report.containsKey('actions') || (capture is Map && capture['status'] == 'unavailable')) continue;
    final receipts = capture is Map ? capture['receipts'] : null;
    final steps0 = report['steps'];
    if (capture is! Map ||
        !const ['observed', 'not-observed'].contains(capture['status']) ||
        capture['coverage'] != 'not-established' ||
        capture['overflow'] is! bool ||
        receipts is! List ||
        receipts.length > 256 ||
        capture['status'] != (receipts.isNotEmpty ? 'observed' : 'not-observed') ||
        steps0 is! List ||
        steps0.length > 2048) {
      throw const MomentsError('Invalid journey capture');
    }
    final steps = <String, String>{}, requests = <Object?>{};
    for (final step in steps0) {
      if (step is! Map ||
          !_uuidOk(step['id']) ||
          step['name'] is! String ||
          !RegExp(r'^[a-z_][a-zA-Z0-9_-]{0,127}$').hasMatch(step['name'] as String) ||
          steps.containsKey(step['id'])) {
        throw const MomentsError('Invalid journey steps');
      }
      steps[step['id'] as String] = step['name'] as String;
    }
    input['capture'] = capture['status'];
    var truncated = capture['overflow'] as bool;
    for (final raw in receipts) {
      if (raw is! Map) throw const MomentsError('Invalid action receipt');
      final step = raw['step'];
      final receipt = actionReceipt({
        for (final MapEntry(:key, :value) in raw.entries)
          if (key != 'step') key: value,
      });
      if (!steps.containsKey(receipt['gesture']) ||
          steps[receipt['gesture']] != step ||
          requests.contains(receipt['request'])) {
        throw const MomentsError('Receipt does not match journey steps');
      }
      requests.add(receipt['request']);
      truncated = truncated || receipt['truncated'] == true;
      for (final action in receipt['actions']! as List) {
        action as Map;
        if (action['resource'] != identified['resource'] || action['action'] != identified['action']) continue;
        input['matchingSpans'] = (input['matchingSpans']! as int) + 1;
        observations.add({
          'moment': report['name'],
          'report': id,
          'journeyStatus': report['status'],
          'step': step,
          'gesture': receipt['gesture'],
          'request': receipt['request'],
          ...action.cast<String, Object?>(),
        });
      }
    }
    input['truncated'] = truncated;
  }
  return {
    'version': 1,
    'status': 'associated',
    'executed': false,
    'verification': 'not-performed',
    'target': {'resource': identified['resource'], 'action': identified['action']},
    'coverage': 'not-established',
    'applicability': 'historical-only; current sources, manifest, runtime and effects not verified',
    'scope':
        'Local reports of gesture-originated requests; not signed attestations, action success or assertion coverage',
    'candidates': [
      for (final name in candidates)
        {
          'name': name,
          'coverage': 'unverified',
          'observation': observations.any((item) => item['moment'] == name)
              ? 'recorded'
              : 'not-observed-in-supplied-reports',
        },
    ],
    'inputs': inputs,
    'observations': observations,
    'limitations': const [
      'No candidate is excluded and no review question is resolved by these observations.',
      'Failed journeys may contain observed actions; span-finished does not mean successful commit.',
      'Missing, truncated or absent receipts do not prove that an action was not executed.',
      'Jobs, detached work, other entry points and assertion/effect coverage remain unresolved.',
    ],
  };
}

Map<String, Object?> readReviewEvidence(String planFile, List<String> evidenceFiles) {
  if (evidenceFiles.isEmpty || evidenceFiles.length > 32) {
    throw const MomentsError('Supply between 1 and 32 journey reports');
  }
  final plan = _readJson(planFile);
  final result = reviewEvidence(plan.value, evidenceFiles.map(_readJson).toList());
  final value = plan.value! as Map;
  return {
    ...result,
    'plan': {'sha256': plan.sha256, 'status': value['status'], 'verification': value['verification']},
  };
}
