import 'dart:async';

import 'package:mana/mana.dart' show uuidV4;

import 'json.dart';

final class JourneyError implements Exception {
  const JourneyError(this.message, [this.status = 'unavailable']);
  final String message;
  final String status;

  @override
  String toString() => message;
}

final _target = RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$');
const _criteria = ['ui_equals', 'backend_equals'];

void validateSteps(Map<String, Object?> scene, {bool navigation = false}) {
  final checks = scene['checks'] ?? const [];
  if (checks is! List) throw const JourneyError('Invalid check declaration');
  final steps = scene['steps'];
  if (steps is! List || (!navigation && steps.isEmpty) || steps.length > 32) {
    throw const JourneyError('Declare 1–32 journey steps before running');
  }
  final declared = checks.cast<Map>();
  final stepList = steps.cast<Map>();
  if (!navigation && !declared.any((c) => c['scope'] != 'step' && _criteria.contains(c['kind']))) {
    throw const JourneyError('A journey requires an observed UI or backend criterion');
  }
  for (final check in declared.where((c) => c['scope'] == 'step')) {
    if (!_criteria.contains(check['kind']) ||
        !stepList.any((s) => (s['until'] as List?)?.contains(check['name']) ?? false)) {
      throw const JourneyError('Step checks must be observed by a declared step');
    }
  }
  final names = <String>{};
  for (final (index, step) in stepList.indexed) {
    final until = step['until'];
    final kind = step['kind'], inputRef = step['inputRef'];
    final invalid =
        step['name'] is! String ||
        (step['name'] as String).isEmpty ||
        names.contains(step['name']) ||
        !const ['tap', 'fill', 'reveal'].contains(kind) ||
        !_target.hasMatch('${step['target'] ?? ''}') ||
        ((kind == 'fill' || inputRef != null) && !_target.hasMatch('${inputRef ?? ''}')) ||
        until is! List ||
        (!navigation && kind == 'tap' && until.isEmpty && index != stepList.length - 1) ||
        until.length > 32 ||
        !until.every((name) => declared.any((c) => c['name'] == name && _criteria.contains(c['kind'])));
    if (invalid) throw const JourneyError('Invalid journey target, input reference or postcondition');
    names.add(step['name'] as String);
  }
}

typedef Request = Future<Map<String, Object?>> Function(String path, [Map<String, Object?>? body]);
typedef Evaluate =
    List<Map<String, Object?>> Function(
      List<Map<String, Object?>> checks, {
      required Object? expected,
      required Object? observed,
      required Object? properties,
      required Object? backend,
    });

/// Runs the declared steps against an already prepared runtime: never
/// reseeds, recompiles or retries gestures.
Future<void> executeSteps({
  required Map<String, Object?> scene,
  required Request request,
  required Object? revision,
  required Object? client,
  required Object? expected,
  required Object? properties,
  required Evaluate evaluate,
  required Map<String, Object?> report,
  void Function(Map<String, Object?> inspection)? validateInspection,
  Future<Object?> Function()? settle,
  int timeout = 8000,
  int poll = 100,
  int wait = 250,
}) async {
  final receipts = <Map<String, Object?>>[];
  report['steps'] = receipts;
  final checksDeclared = (scene['checks'] as List? ?? const []).cast<Map<String, Object?>>();
  for (final step in (scene['steps']! as List).cast<Map<String, Object?>>()) {
    final id = uuidV4(), started = nowMs();
    final receipt = <String, Object?>{
      'name': step['name'],
      'id': id,
      'status': 'unavailable',
      'dispatch': 'unknown',
      'until': step['until'],
    };
    receipts.add(receipt);
    double? dispatchedAt;
    try {
      final result = await request('/journey/${step['kind']}', {
        'id': id,
        'revision': revision,
        'client': client,
        'target': step['target'],
        if (step['inputRef'] != null) 'inputRef': step['inputRef'],
      });
      if (result['id'] != id || result['revision'] != revision || result['client'] != client) {
        throw const JourneyError('Gesture receipt has a different runtime identity');
      }
      receipt['dispatch'] = result['status'];
      receipt['transport'] = result['transport'];
      dispatchedAt = nowMs();
      receipt['dispatchRequestMs'] = dispatchedAt - started;
      if (result['timing'] != null) receipt['timing'] = result['timing'];
      if (result['status'] != 'dispatched') {
        receipt['dispatchReason'] = result['reason'];
        receipt['reason'] = result['reason'];
        final rejected = result['status'] == 'rejected';
        receipt['status'] = rejected ? 'failed' : 'unavailable';
        throw JourneyError(
          rejected
              ? 'Flutter rejected the declared gesture'
              : 'Gesture outcome uncertain; inspect before running again',
          receipt['status']! as String,
        );
      }
      if (settle != null) receipt['capture'] = await settle();
      final until = (step['until'] as List?) ?? const [];
      final checks = checksDeclared.where((c) => until.contains(c['name'])).toList();
      final deadline = nowMs() + timeout;
      if (checks.isEmpty) {
        receipt['status'] = 'passed';
        receipt['meaning'] = settle != null
            ? 'Operation dispatched and declared UI captured; no business criterion evaluated for this step'
            : 'Operation dispatched; application effects are checked by later steps and final criteria';
        continue;
      }
      Object? observation;
      while (true) {
        final look = await request(
          observation is int ? '/moments/look?after=$observation&wait=$wait' : '/moments/look',
        );
        observation = look['observation'];
        final observed = look['observed'] as Map?;
        if (look['revision'] != revision || observed?['client'] != client || look['codeChanged'] == true) {
          throw const JourneyError('Runtime changed while awaiting the gesture outcome');
        }
        final inspection = await request('/moments/inspect');
        validateInspection?.call(inspection);
        final lastReported = ((inspection['screen'] as Map?)?['lastReported']) as Map?;
        if ((inspection['moment'] as Map?)?['revision'] != revision ||
            lastReported?['matchesRevision'] != true ||
            !deepEqual(observed?['projection'], lastReported?['projection'])) {
          if (nowMs() >= deadline) throw const JourneyError('UI did not settle after gesture');
        } else {
          final outcomes = evaluate(
            checks,
            expected: expected,
            observed: observed!['projection'],
            properties: properties,
            backend: inspection['backend'],
          );
          receipt['checks'] = outcomes;
          receipt['status'] = outcomes.any((c) => c['status'] == 'unavailable')
              ? 'unavailable'
              : outcomes.any((c) => c['status'] == 'failed')
              ? 'failed'
              : 'passed';
          if (receipt['status'] == 'passed') break;
          if (nowMs() >= deadline) {
            throw JourneyError('Declared gesture postcondition was not reached', receipt['status']! as String);
          }
        }
        // A bridge that cannot wait for the next report answers at once.
        if (observation is! int) await Future<void>.delayed(Duration(milliseconds: poll));
      }
    } on Object catch (error) {
      receipt['status'] = error is JourneyError ? error.status : 'unavailable';
      if (receipt['status'] == 'unavailable') receipt.remove('checks');
      if (error is JourneyError) receipt['reason'] = error.message;
      rethrow;
    } finally {
      receipt['durationMs'] = nowMs() - started;
      if (dispatchedAt != null) receipt['postconditionMs'] = nowMs() - dispatchedAt;
    }
  }
}
