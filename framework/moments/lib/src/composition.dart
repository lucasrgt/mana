import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'check.dart';
import 'journey.dart';
import 'json.dart';
import 'projection.dart';

Never _fail(String message) => throw JourneyError(message);
bool _exact(Object? value, List<String> keys) => value is Map && value.keys.every(keys.contains);
bool _name(Object? value) => value is String && RegExp(r'^[a-z][a-z0-9_-]{0,79}$').hasMatch(value);
String _hash(Object? value) => sha256.convert(utf8.encode(jsonEncode(value))).toString();

/// One prepared runtime a composition stage observes.
final class CompositionConnection {
  const CompositionConnection({required this.request, this.validateInspection});
  final Request request;
  final void Function(Map<String, Object?> inspection)? validateInspection;
}

/// Raised when an explicit interruption stops a composition.
final class Interruption {
  var _aborted = false;
  final _listeners = <void Function()>[];
  bool get aborted => _aborted;
  void abort() {
    if (_aborted) return;
    _aborted = true;
    for (final listener in [..._listeners]) {
      listener();
    }
  }

  void onAbort(void Function() listener) => _listeners.add(listener);
  void off(void Function() listener) => _listeners.remove(listener);
}

/// Selects existing declarations. A composition may not redefine recipes,
/// ancestry, targets, values or check predicates. The WHOLE plan is validated
/// first.
Map<String, Object?> compileComposition(Object? plan, Map<String, Object?> manifest) {
  if (plan is! Map ||
      !_exact(plan, const ['version', 'stages']) ||
      plan['version'] != 1 ||
      plan['stages'] is! List ||
      (plan['stages'] as List).isEmpty ||
      (plan['stages'] as List).length > 64) {
    _fail('Composition requires version 1 and 1–64 stages');
  }
  final ids = <String>{}, surfaces = <String>{};
  final moments = manifest['moments'];
  final stages = [
    for (final stage in plan['stages'] as List)
      () {
        if (!_exact(stage, const ['id', 'surface', 'moment', 'kind', 'steps', 'checks']) ||
            !_name((stage as Map)['id']) ||
            ids.contains(stage['id']) ||
            !_name(stage['surface']) ||
            !_name(stage['moment']) ||
            !const ['steps', 'checkpoint'].contains(stage['kind'])) {
          _fail('Invalid or duplicate composition stage');
        }
        ids.add(stage['id'] as String);
        surfaces.add(stage['surface'] as String);
        if (moments is! Map || !moments.containsKey(stage['moment'])) _fail('Composition references an unknown Moment');
        final scene = asObject(jsonCopy(moments[stage['moment']]));
        final checks = scene['checks'] ?? const <Object?>[];
        final properties = (jsonCopy(propertiesFor(manifest, (scene['projection'] as Map?)?['route'])) as Map?)
            ?.cast<String, Object?>();
        try {
          validateChecks(checks, properties, navigation: true);
        } on Object {
          _fail('Invalid composition criterion declaration');
        }
        if (checks is! List ||
            checks.map((c) => (c as Map)['name']).toSet().length != checks.length ||
            checks.any(
              (c) =>
                  !_name((c as Map)['name']) || !const ['ui_equals', 'backend_equals', 'restored'].contains(c['kind']),
            )) {
          _fail('Composition requires uniquely named supported criteria');
        }
        final declared = checks.cast<Map>().map((c) => c.cast<String, Object?>()).toList();
        List<Map<String, Object?>> select(Object? names, List<Map<String, Object?>> items) {
          if (names is! List ||
              names.isEmpty ||
              names.toSet().length != names.length ||
              names.any((n) => !items.any((item) => item['name'] == n))) {
            _fail('Composition references missing or duplicate selections');
          }
          return [for (final n in names) items.firstWhere((item) => item['name'] == n)];
        }

        var steps = <Map<String, Object?>>[], selected = <Map<String, Object?>>[];
        if (stage['kind'] == 'steps') {
          if (stage.containsKey('checks')) _fail('A steps stage cannot redefine its postconditions');
          validateSteps(scene, navigation: true);
          final sceneSteps = (scene['steps']! as List).cast<Map>().map((s) => s.cast<String, Object?>()).toList();
          steps = select(stage['steps'], sceneSteps);
          final indices = steps.map(sceneSteps.indexOf).toList();
          for (var i = 1; i < indices.length; i++) {
            if (indices[i] <= indices[i - 1]) _fail('Selected steps must preserve declaration order');
          }
          selected = [
            for (final check in declared)
              if (steps.any((s) => (s['until'] as List?)?.contains(check['name']) ?? false)) check,
          ];
        } else {
          if (stage.containsKey('steps')) _fail('A checkpoint cannot dispatch steps');
          final finals = [
            for (final check in declared)
              if (check['scope'] != 'step') check,
          ];
          selected = stage.containsKey('checks') ? select(stage['checks'], finals) : finals;
          if (selected.isEmpty) _fail('A checkpoint needs observed criteria');
          // Restored checks require a restoration receipt, which this prepared-
          // runtime executor intentionally does not manufacture.
          if (selected.any((c) => c['kind'] == 'restored'))
            _fail('Restoration criteria require the restoration runner');
        }
        final finalCount = declared.where((c) => c['scope'] != 'step').length;
        return {
          ...asObject(jsonCopy(stage)),
          'scene': {...scene, 'steps': steps, 'checks': selected},
          'properties': properties,
          'coverage': stage['kind'] == 'steps'
              ? 'declared-step-postconditions'
              : selected.length == finalCount
              ? 'all-final-criteria'
              : 'selected-final-criteria',
        };
      }(),
  ];
  if (surfaces.length > 8) _fail('Composition supports at most 8 surfaces');
  return {'planDigest': _hash(plan), 'manifestDigest': _hash(manifest), 'stages': stages};
}

/// The adapter owns preparation, leases, private inputs and cleanup. [connect]
/// returns a prepared bridge; hooks are explicit local adapter operations
/// (e.g. fault injection), never protocol criteria or permission to replay a
/// gesture.
Future<Map<String, Object?>> executeComposition({
  required Object? plan,
  required Map<String, Object?> manifest,
  required Future<CompositionConnection> Function({required String surface, required String moment}) connect,
  Map<String, Object?>? report,
  Future<void> Function(String id)? beforeStage,
  Future<void> Function(String id)? afterStage,
  void Function(Map<String, Object?> report)? onProgress,
  Interruption? signal,
  int timeout = 8000,
  int poll = 100,
}) async {
  final compiled = compileComposition(plan, manifest);
  if (timeout <= 0 || poll <= 0) _fail('Composition requires a connector and bounded observation timing');
  report ??= {};
  final receipts = <Map<String, Object?>>[];
  report.addAll({
    'kind': 'composition',
    'version': 1,
    'status': 'running',
    'planDigest': compiled['planDigest'],
    'manifestDigest': compiled['manifestDigest'],
    'meaning': 'Historical stage observations; not a final state approval of every referenced Moment',
    'stages': receipts,
  });
  final pins = <String, Map<String, Object?>>{};
  void active() {
    if (signal?.aborted ?? false) _fail('Composition interrupted; effects were not rolled back');
  }

  try {
    for (final stage in (compiled['stages']! as List).cast<Map<String, Object?>>()) {
      final surface = stage['surface']! as String;
      final scene = (stage['scene']! as Map).cast<String, Object?>();
      final receipt = <String, Object?>{
        'id': stage['id'],
        'surface': surface,
        'moment': stage['moment'],
        'kind': stage['kind'],
        'coverage': stage['coverage'],
        'status': 'unavailable',
      };
      receipts.add(receipt);
      onProgress?.call(report);
      final started = Stopwatch()..start();
      try {
        active();
        await beforeStage?.call(stage['id']! as String);
        active();
        final connection = await connect(surface: surface, moment: stage['moment']! as String);
        final validate = connection.validateInspection ?? (_) {};
        Future<Map<String, Object?>> request(String path, [Map<String, Object?>? body]) {
          active();
          return connection.request(path, body);
        }

        Future<
          ({Map<String, Object?> look, Map<String, Object?> inspection, Map<String, Object?> identity, bool settled})
        >
        observe() async {
          final look = await request('/moments/look');
          final identity = {'client': (look['observed'] as Map?)?['client'], 'revision': look['revision']};
          if (identity['client'] == null || !look.containsKey('revision') || look['codeChanged'] == true) {
            _fail('Composition runtime is missing or changed');
          }
          if (pins.containsKey(surface) && !deepEqual(pins[surface], identity)) {
            _fail('Composition runtime changed between stages');
          }
          if (!pins.containsKey(surface)) {
            if (pins.values.any((pin) => pin['client'] == identity['client'])) {
              _fail('Composition surfaces must have distinct runtime clients');
            }
            pins[surface] = identity;
          }
          final inspection = await request('/moments/inspect');
          validate(inspection);
          final reported = (inspection['screen'] as Map?)?['lastReported'] as Map?;
          final settled =
              (inspection['moment'] as Map?)?['revision'] == identity['revision'] &&
              reported?['matchesRevision'] == true &&
              deepEqual((look['observed'] as Map?)?['projection'], reported?['projection']);
          return (look: look, inspection: inspection, identity: identity, settled: settled);
        }

        final first = await observe();
        receipt['runtime'] = first.identity;
        if (!first.settled) _fail('Composition runtime has not settled before stage');
        if (stage['kind'] == 'steps') {
          await executeSteps(
            scene: scene,
            request: request,
            client: first.identity['client'],
            revision: first.identity['revision'],
            expected: scene['projection'],
            properties: stage['properties'],
            evaluate: evaluateChecks,
            report: receipt,
            validateInspection: validate,
            timeout: timeout,
            poll: poll,
          );
          // Even a gesture with no until must not mask a disconnected or
          // replaced runtime. This read does not invent a business postcondition.
          await observe();
        } else {
          final deadline = DateTime.now().add(Duration(milliseconds: timeout));
          var snapshot = first;
          while (true) {
            if (snapshot.settled) {
              final checks = evaluateChecks(
                (scene['checks']! as List).cast<Map<String, Object?>>(),
                expected: scene['projection'],
                observed: (snapshot.look['observed']! as Map)['projection'],
                backend: snapshot.inspection['backend'],
                properties: stage['properties'],
              );
              receipt['checks'] = checks;
              final status = checks.any((c) => c['status'] == 'unavailable')
                  ? 'unavailable'
                  : checks.any((c) => c['status'] == 'failed')
                  ? 'failed'
                  : 'passed';
              if (status == 'passed') break;
              if (!DateTime.now().isBefore(deadline)) {
                throw JourneyError('Composition checkpoint criteria were not reached', status);
              }
            } else if (!DateTime.now().isBefore(deadline)) {
              _fail('Composition checkpoint did not settle');
            }
            await Future<void>.delayed(Duration(milliseconds: poll));
            snapshot = await observe();
          }
        }
        receipt['observedAt'] = DateTime.now().toUtc().toIso8601String();
        active();
        await afterStage?.call(stage['id']! as String);
        active();
        receipt['status'] = 'passed';
      } on JourneyError catch (error) {
        receipt
          ..['status'] = error.status
          ..['reason'] = error.message;
        rethrow;
      } on Object {
        receipt['status'] = 'unavailable';
        rethrow;
      } finally {
        receipt['durationMs'] = started.elapsedMicroseconds / 1000;
        onProgress?.call(report);
      }
    }
    report['status'] = 'passed';
    return report;
  } on JourneyError catch (error) {
    report['status'] = error.status;
    rethrow;
  } on Object {
    report['status'] = 'unavailable';
    rethrow;
  }
}
