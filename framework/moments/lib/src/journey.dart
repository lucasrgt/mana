import 'dart:async';

import 'package:mana/runtime.dart' show uuidV4;

import 'json.dart';
import 'progress.dart';

final class JourneyError implements Exception {
  const JourneyError(this.message, [this.status = 'unavailable']);
  final String message;
  final String status;

  @override
  String toString() => message;
}

final _target = RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$');

/// What a journey can wait for: criteria observed after a gesture.
const criteria = ['ui_equals', 'backend_equals', 'offered', 'not_offered'];

/// A verb as records list what they offer and `VerbGate` keys its control:
/// `booking.pay`, or `booking.pay:<id>` for one record's.
final verbIdentity = RegExp(r'^[a-z][a-z0-9_-]{0,63}\.[a-z][a-z0-9_]{0,63}(?::[A-Za-z0-9_.-]{1,64})?$');

/// A `verb:` step's or check's verb: `type.verb`, without a record.
bool isVerb(Object? value) => value is String && verbIdentity.hasMatch(value) && !value.contains(':');

bool _offers(Map check) => check['kind'] == 'offered' || check['kind'] == 'not_offered';

/// An `offered` / `not_offered` check against the verbs the screen's mounted
/// controls reported (`type.verb` or `type.verb:<id>`).
Map<String, Object?> offeredOutcome(Map check, Object? offered) {
  final verb = check['verb']! as String, wanted = check['kind'] == 'offered';
  if (offered is! List) {
    return {
      'name': check['name'],
      'status': 'unavailable',
      'verb': verb,
      'reason': 'The screen did not report what its controls offer',
    };
  }
  final controls = [
    for (final identity in offered.cast<String>())
      if (identity == verb || identity.startsWith('$verb:')) identity,
  ];
  return {
    'name': check['name'],
    'status': controls.isNotEmpty == wanted ? 'passed' : 'failed',
    'verb': verb,
    'expected': wanted ? 'offered' : 'not-offered',
    'observed': controls.take(16).toList(),
    'meaning':
        'Verbs the mounted controls (VerbGate) offered in the active UI; not proof the server would accept them.',
  };
}

void validateSteps(Map<String, Object?> scene) {
  final checks = scene['checks'] ?? const [];
  if (checks is! List) throw const JourneyError('Invalid check declaration');
  final steps = scene['steps'];
  if (steps is! List || steps.isEmpty || steps.length > 32) {
    throw const JourneyError('Declare 1–32 journey steps before running');
  }
  final declared = checks.cast<Map>();
  final stepList = steps.cast<Map>();
  if (!declared.any((c) => c['scope'] != 'step' && criteria.contains(c['kind']))) {
    throw const JourneyError('A journey requires an observed UI or backend criterion');
  }
  for (final check in declared.where((c) => c['scope'] == 'step')) {
    if (!criteria.contains(check['kind']) ||
        !stepList.any((s) => (s['until'] as List?)?.contains(check['name']) ?? false)) {
      throw const JourneyError('Step checks must be observed by a declared step');
    }
  }
  final names = <String>{};
  for (final (index, step) in stepList.indexed) {
    final until = step['until'];
    final kind = step['kind'], inputRef = step['inputRef'], verb = step['verb'];
    final invalid =
        step['name'] is! String ||
        (step['name'] as String).isEmpty ||
        names.contains(step['name']) ||
        !gestureKinds.contains(kind) ||
        (kind == 'swipe' && !swipeDirections.contains(step['direction'])) ||
        (kind != 'swipe' && step['direction'] != null) ||
        ((kind == 'back') != (step['target'] == backTarget)) ||
        !_target.hasMatch('${step['target'] ?? ''}') ||
        ((kind == 'fill' || inputRef != null) && !_target.hasMatch('${inputRef ?? ''}')) ||
        (verb != null && (kind != 'tap' || !isVerb(verb) || step['target'] != 'verb:$verb')) ||
        until is! List ||
        (kind == 'tap' && until.isEmpty && index != stepList.length - 1) ||
        until.length > 32 ||
        !until.every((name) => declared.any((c) => c['name'] == name && criteria.contains(c['kind'])));
    if (invalid) throw const JourneyError('Invalid journey target, input reference or postcondition');
    names.add(step['name'] as String);
  }
}

/// What a step can do (`MomentGestures` in live_ui carries each out).
const gestureKinds = ['tap', 'fill', 'reveal', 'back', 'swipe', 'long_press', 'submit'];

/// Where a `swipe` drags its target.
const swipeDirections = ['left', 'right', 'up', 'down'];

/// The target a `back` step names: the platform, not a widget.
const backTarget = 'system.back';

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
/// reseeds, recompiles or retries gestures. Each postcondition waits while
/// the app shows progress ([ProgressWait]): [timeout] after the last sign of
/// it, [limit] at most.
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
  int timeout = 8000,
  int limit = 30000,
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
      'verb': ?step['verb'],
    };
    receipts.add(receipt);
    double? dispatchedAt;
    ProgressWait? progress;
    var lookMs = 0.0, inspectMs = 0.0;
    try {
      final result = await request('/journey/${step['kind']}', {
        'id': id,
        'revision': revision,
        'client': client,
        'target': step['target'],
        if (step['inputRef'] != null) 'inputRef': step['inputRef'],
        if (step['direction'] != null) 'direction': step['direction'],
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
      final until = (step['until'] as List?) ?? const [];
      final checks = checksDeclared.where((c) => until.contains(c['name'])).toList();
      if (checks.isEmpty) {
        receipt['status'] = 'passed';
        receipt['meaning'] = 'Operation dispatched; application effects are checked by later steps and final criteria';
        continue;
      }
      final waiting = progress = ProgressWait(idleMs: timeout, limitMs: limit, started: dispatchedAt);
      Object? observation;
      while (true) {
        var sent = nowMs();
        final look = await request(
          observation is int ? '/moments/look?after=$observation&wait=$wait' : '/moments/look',
        );
        lookMs += nowMs() - sent;
        waiting.observe(look);
        observation = look['observation'];
        final observed = look['observed'] as Map?;
        if (look['revision'] != revision || observed?['client'] != client || look['codeChanged'] == true) {
          throw const JourneyError('Runtime changed while awaiting the gesture outcome');
        }
        sent = nowMs();
        final inspection = await request('/moments/inspect');
        inspectMs += nowMs() - sent;
        validateInspection?.call(inspection);
        final lastReported = ((inspection['screen'] as Map?)?['lastReported']) as Map?;
        if ((inspection['moment'] as Map?)?['revision'] != revision ||
            lastReported?['matchesRevision'] != true ||
            !deepEqual(observed?['projection'], lastReported?['projection'])) {
          if (waiting.expired) throw JourneyError('UI did not settle after gesture (${_ended(waiting)})');
        } else {
          final others = evaluate(
            checks.where((c) => !_offers(c)).toList(),
            expected: expected,
            observed: observed!['projection'],
            properties: properties,
            backend: inspection['backend'],
          ).iterator;
          final outcomes = [
            for (final check in checks)
              if (_offers(check)) offeredOutcome(check, observed['offered']) else if (others.moveNext()) others.current,
          ];
          receipt['checks'] = outcomes;
          receipt['status'] = outcomes.any((c) => c['status'] == 'unavailable')
              ? 'unavailable'
              : outcomes.any((c) => c['status'] == 'failed')
              ? 'failed'
              : 'passed';
          if (receipt['status'] == 'passed') break;
          if (waiting.expired) {
            throw JourneyError(
              'Declared gesture postcondition was not reached (${_ended(waiting)})',
              receipt['status']! as String,
            );
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
      if (progress != null) receipt['wait'] = {...progress.receipt(), 'lookMs': lookMs, 'inspectMs': inspectMs};
    }
  }
}

String _ended(ProgressWait wait) => wait.reason == 'limit'
    ? 'still progressing at the ${_seconds(wait.limitMs)} s limit'
    : 'no progress for ${_seconds(wait.idleMs)} s';

String _seconds(int ms) => ms % 1000 == 0 ? '${ms ~/ 1000}' : (ms / 1000).toStringAsFixed(2);
