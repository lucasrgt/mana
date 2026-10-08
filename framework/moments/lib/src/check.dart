import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show openPrivate, uuidV4;
import 'package:path/path.dart' as p;

import 'action_evidence.dart';
import 'canonical.dart';
import 'dart_sources.dart';
import 'declaration_sources.dart';
import 'errors.dart';
import 'flutter_target.dart';
import 'journey.dart';
import 'json.dart';
import 'profile.dart';
import 'projection.dart';
import 'protocol.dart';
import 'refresh_check.dart';
import 'verdict.dart';

final class _Unavailable implements Exception {
  const _Unavailable(this.message);
  final String message;
}

bool _own(Object? value, String key) => value is Map && value.containsKey(key);
bool _scalar(Object? value) => value is String || value is bool || value is num;

Map<String, Object?> _sources(
  String project,
  String manifestFile,
  Map<String, Object?> manifest,
  Map<String, Object?> scene,
  DartSources inventory,
) {
  final files = <String, String>{
    for (final path in (manifest['watch']! as List).cast<String>())
      path: () {
        final absolute = p.normalize(p.join(project, path)), local = p.relative(absolute, from: project);
        if (local == '.' || local.startsWith('../') || local == '..' || !path.endsWith('.dart')) {
          throw const _Unavailable('Invalid watched source path');
        }
        return hashBytes(File(absolute).readAsBytesSync());
      }(),
  };
  Map<String, Object?>? declaration;
  if (scene['source'] != null) {
    final source = declarationSource(project, manifestFile, scene['source']);
    if (source['status'] != 'current') {
      throw const _Unavailable('Ash declaration changed since export; run moments sync');
    }
    declaration = {'file': source['file'], 'sha256': source['sha256'], 'configDigest': source['configDigest']};
  }
  return {
    'manifest': hashBytes(File(manifestFile).readAsBytesSync()),
    'files': files,
    'declaration': ?declaration,
    'dart': inventory.snapshot(fresh: true),
  };
}

List<Map<String, Object?>> evaluateChecks(
  List<Map<String, Object?>> checks, {
  required Object? expected,
  required Object? observed,
  required Object? properties,
  required Object? backend,
}) {
  final saved = restorableProjection(asObject(expected), (properties as Map?)?.cast()),
      restored = restorableProjection(asObject(observed), (properties)?.cast());
  final observedMap = asObject(observed), backendMap = backend as Map?;
  return [
    for (final check in checks)
      () {
        final name = check['name'], field = check['field'] as String?;
        if (check['kind'] == 'restored') {
          final changedFields = {
            ...saved.keys,
            ...restored.keys,
          }.where((key) => !deepEqual(saved[key], restored[key])).toList();
          final expectedField = field == null || deepEqual(observedMap[field], check['equals']);
          return <String, Object?>{
            'name': name,
            'status': changedFields.isEmpty && expectedField ? 'passed' : 'failed',
            'expected': {
              'projectionDigest': canonicalDigest(saved),
              if (field != null) ...{'field': field, 'value': check['equals']},
            },
            'observed': {
              'projectionDigest': canonicalDigest(restored),
              'changedFields': changedFields,
              'expectedFieldMatches': expectedField,
            },
            'meaning':
                'Declared state reported after restoration; not a screenshot or arbitrary widget-memory comparison.',
          };
        }
        if (check['kind'] == 'ui_equals') {
          final actual = observedMap[field];
          if (!_own(observedMap, field!) || !_scalar(actual)) {
            return {
              'name': name,
              'status': 'unavailable',
              'reason': 'Declared UI observation is unavailable or not a scalar',
            };
          }
          return {
            'name': name,
            'status': deepEqual(actual, check['equals']) ? 'passed' : 'failed',
            'field': field,
            'expected': check['equals'],
            'observed': actual,
            'meaning': 'Value reported by the active UI; not proof of a gesture or backend persistence.',
          };
        }
        final projection = backendMap?['projection'] as Map?;
        if (!const ['ready', 'changed'].contains(backendMap?['status']) || !_own(projection, field!)) {
          return {
            'name': name,
            'status': 'unavailable',
            'reason': 'Backend observation unavailable or missing declared field',
          };
        }
        final match = check['match']! as String;
        final observedIdentity = ((properties)?[match] as Map?)?['restore'] == false;
        final identity = asObject(observedIdentity ? observed : expected)[match];
        if (identity is! String || identity.isEmpty || projection![match] != identity) {
          return {
            'name': name,
            'status': 'unavailable',
            'reason': 'Backend observation does not identify the UI entity',
          };
        }
        final actual = projection[field];
        // Only scalar criteria are exported; never include a backend payload in evidence.
        if (!_scalar(actual)) {
          return {'name': name, 'status': 'unavailable', 'reason': 'Backend criterion is not a scalar'};
        }
        return {
          'name': name,
          'status': deepEqual(actual, check['equals']) ? 'passed' : 'failed',
          'expected': check['equals'],
          'observed': actual,
          'field': field,
          'identityMatched': true,
          'identitySource': observedIdentity ? 'observed-ui' : 'restored-ui',
          'source': backendMap!['source'],
          'observedAt': backendMap['observedAt'],
        };
      }(),
  ];
}

void validateChecks(Object? checks, Map<String, Object?>? properties, {bool navigation = false}) {
  if (checks is! List || (!navigation && checks.isEmpty) || checks.length > 64) {
    throw const _Unavailable('This Moment has no bounded on-demand checks');
  }
  final declared = checks.cast<Map>();
  if (!navigation && !declared.any((c) => c['scope'] != 'step')) {
    throw const _Unavailable('A Moment requires a final criterion');
  }
  final names = <String>{};
  for (final c in declared) {
    if (c['name'] is! String ||
        (c['name'] as String).isEmpty ||
        names.contains(c['name']) ||
        !const ['restored', 'ui_equals', 'backend_equals'].contains(c['kind'])) {
      throw const _Unavailable('Invalid or unsupported check declaration');
    }
    if (c['scope'] != null && !const ['step', 'final'].contains(c['scope'])) {
      throw const _Unavailable('Invalid check scope');
    }
    names.add(c['name'] as String);
    if (c.containsKey('field') && (c['field'] is! String || !_scalar(c['equals']))) {
      throw const _Unavailable('Check expects a scalar field comparison');
    }
    if (c['kind'] == 'backend_equals' && (c['field'] is! String || c['match'] is! String)) {
      throw const _Unavailable('Backend check needs a matching UI identity');
    }
    if (c['kind'] == 'ui_equals' && c['field'] is! String) throw const _Unavailable('UI check needs a field');
    if (properties != null &&
        ((c['match'] != null && !_own(properties, c['match'] as String)) ||
            (c['kind'] != 'backend_equals' && c['field'] != null && !_own(properties, c['field'] as String)))) {
      throw const _Unavailable('Check references an undeclared UI field');
    }
    if (c['kind'] == 'restored' && (properties?[c['field']] as Map?)?['restore'] == false) {
      throw const _Unavailable('Observation fields require ui_equals checks');
    }
  }
}

final _uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
final _hash = RegExp(r'^[a-f0-9]{64}$');

/// Only allowlisted build identity is copied to evidence, never env or logs.
List<Map<String, Object?>> _backendIdentity(Object? raw) {
  final status = raw as Map?;
  if (status?['phase'] == 'waiting-runtime') {
    throw const _Unavailable(
      'Flutter is waiting for its first Moment observation; open the app. Pending edits will apply automatically.',
    );
  }
  if (status == null ||
      !const ['idle', 'ready'].contains(status['phase']) ||
      status['pending'] == true ||
      status['held'] == true) {
    throw const _Unavailable('Backend supervisor is not settled; apply the current code before checking');
  }
  final services = status['services'];
  if (services is! List || services.isEmpty) {
    throw const _Unavailable('Backend service identity is missing; update the Moments supervisor');
  }
  final names = <String>{};
  final identities = [
    for (final service in services.cast<Map>())
      () {
        final source = service['source'] as Map?;
        if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch('${service['name'] ?? ''}') ||
            names.contains(service['name']) ||
            service['phase'] != 'ready' ||
            service['running'] != true ||
            service['codeChanged'] != false ||
            service['generation'] is! String ||
            !_uuid.hasMatch(service['generation'] as String) ||
            source?['current'] is! String ||
            !_hash.hasMatch(source!['current'] as String) ||
            source['current'] != source['applied']) {
          throw const _Unavailable('Backend runtime is missing, stopped or behind the current source');
        }
        names.add(service['name'] as String);
        return <String, Object?>{
          'name': service['name'],
          'generation': service['generation'],
          'sourceDigest': source['current'],
        };
      }(),
  ]..sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));
  return identities;
}

Map<String, Object?>? _targetIdentity(Object? raw, {bool present = false}) {
  if (!present) return null; // Legacy bridges never claim native coverage.
  final target = raw as Map?;
  String? expected;
  try {
    expected = target?['requested'] is String ? flutterTarget(target!['requested'] as String).id : null;
  } on MomentsError {
    expected = null;
  }
  if (expected == null || target!['connected'] != expected) {
    throw const _Unavailable('Flutter device is missing or differs from the requested target');
  }
  return {'requested': target['requested'], 'connected': target['connected'], 'source': 'flutter-daemon'};
}

Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// An explicit command, never an automatic build gate. Opening resumes the
/// saved situation; it does not reset recipes, publish a draft or prepare new
/// data. Writes one proof under `moments/.proofs` and returns its summary.
Future<Map<String, Object?>> checkMoment({
  required String project,
  required String? name,
  required Request request,
  int timeout = 12000,
  int poll = 50,
  bool refresh = false,
  int refreshTimeout = 80000,
  bool journey = false,
  bool navigation = false,
  bool profile = false,
  bool restart = false,
  bool materialized = false,
  String? manifestFile,
}) async {
  manifestFile ??= p.join(project, 'moments/manifest.json');
  journey = journey || navigation || profile;
  final started = nowMs();
  final transport = request;
  Map<String, Object?>? lease;
  var lastHeartbeat = 0.0;
  double? finalObservationStarted;
  Object? actorContext;
  void assertActor(Map<String, Object?>? value) {
    if (materialized &&
        actorContext != null &&
        (!deepEqual(value?['materialization'], actorContext) || (value?['state'] as Map?)?['name'] != name)) {
      throw const _Unavailable('Materialized actor identity changed');
    }
  }

  Future<Map<String, Object?>> guarded(String path, [Map<String, Object?>? data]) async {
    if (materialized &&
        actorContext != null &&
        const ['/journey/tap', '/journey/fill', '/journey/reveal'].contains(path)) {
      assertActor(await transport('/moments/look'));
    }
    if (lease != null && nowMs() - lastHeartbeat > 15000) {
      final renewed = await transport('/journey/lease', {'operation': 'heartbeat', 'journeyId': lease['id']});
      if (renewed['id'] != lease!['id'] || renewed['phase'] != 'active') {
        throw const _Unavailable('Journey ownership was lost');
      }
      lastHeartbeat = nowMs();
    }
    final result = await transport(path, lease != null && data != null ? {...data, 'journeyId': lease['id']} : data);
    if (path == '/moments/look') assertActor(result);
    return result;
  }

  request = guarded;
  final report = <String, Object?>{
    'version': 1,
    'id': uuidV4(),
    'name': name,
    'startedAt': DateTime.now().toUtc().toIso8601String(),
    'status': 'unavailable',
    'checks': <Object?>[],
  };
  String? phase = 'declaration';
  var phaseStarted = started;
  var profileNeedsBackend = false;
  void markPhase(String? next) {
    if (profile && phase != null) {
      final timings = (report['timings'] ??= <String, Object?>{}) as Map<String, Object?>;
      timings[phase!] = ((timings[phase] as num?) ?? 0) + nowMs() - phaseStarted;
    }
    phase = next;
    phaseStarted = nowMs();
  }

  if (journey) {
    report['operation'] = 'journey';
    report['stage'] = 'prepare';
  }
  try {
    if (materialized && (refresh || restart)) {
      throw const _Unavailable('Materialized actors cannot refresh or restart through the legacy checker');
    }
    if (refresh) {
      report['operation'] = 'refresh-check';
      report['stage'] = 'declaration';
      name = ((await request('/moments/look'))['state'] as Map?)?['name'] as String?;
      report['name'] = name;
    }
    if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name ?? '')) throw const _Unavailable('Choose a named Moment');
    final manifestBytes = File(manifestFile).readAsBytesSync();
    final manifest = (jsonDecode(utf8.decode(manifestBytes)) as Map).cast<String, Object?>();
    final declared = ((manifest['moments'] as Map?)?[name] as Map?)?.cast<String, Object?>();
    if (declared == null) throw const _Unavailable('Unknown Moment');
    final scene = {...declared, 'checks': declared['checks'] ?? <Object?>[], 'steps': declared['steps'] ?? <Object?>[]};
    final checks = (scene['checks']! as List).cast<Map<String, Object?>>();
    Map<String, Object?>? inherited;
    if (materialized) {
      inherited = await request('/moments/look');
      actorContext = jsonCopy(inherited['materialization']);
      final context = actorContext as Map?;
      if (context == null ||
          context.keys.any((key) => !const ['instanceId', 'moment', 'from', 'manifest'].contains(key)) ||
          context['moment'] != name ||
          context['manifest'] != hashBytes(manifestBytes) ||
          !RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$').hasMatch('${context['instanceId'] ?? ''}') ||
          ![scene['from'], name].contains(context['from'])) {
        throw const _Unavailable('A matching coordinator-owned actor is required');
      }
      assertActor(inherited);
      report['materialization'] = actorContext;
      report['operation'] = journey ? 'materialized-journey' : 'materialized-check';
    } else {
      assertMaterializable(scene);
    }
    final properties = propertiesFor(manifest, (scene['projection'] as Map?)?['route']);
    validateChecks(checks, properties, navigation: navigation);
    if (journey || checks.any((c) => c['scope'] == 'step')) validateSteps(scene, navigation: navigation);
    if (navigation) {
      report['operation'] = materialized ? 'materialized-navigation' : 'navigation';
      report['verification'] = 'not-performed';
    }
    final inventory = DartSources(project, (manifest['watch']! as List).cast<String>());
    Map<String, Object?> sourceVersion() => _sources(project, manifestFile!, manifest, scene, inventory);
    final version = sourceVersion();
    final dart = version['dart']! as Map;
    void assertDartRuntime(Object? raw) {
      final value = raw as Map?;
      if ((dart['packageCount']! as int) > 0 &&
          (value?['version'] != 1 ||
              value!['current'] != dart['digest'] ||
              value['applied'] != dart['digest'] ||
              value['resolutionChanged'] != false)) {
        throw const _Unavailable(
          'Flutter runtime does not confirm the current local package sources; refresh or restart the Moments launcher',
        );
      }
    }

    if (version['manifest'] != hashBytes(manifestBytes)) throw const _Unavailable('Declaration changed while loading');
    String? commit;
    try {
      final git = Process.runSync('git', ['rev-parse', 'HEAD'], workingDirectory: project);
      if (git.exitCode == 0) commit = (git.stdout as String).trim();
    } on ProcessException {
      commit = null;
    }
    final code = <String, Object?>{
      'commit': commit,
      ...version,
      'scope':
          'Dart source inventory, exported manifest and its selected DSL source when present; not a deployment build identity',
    };
    report['code'] = code;
    ({int id, Map<String, Object?> snapshot})? refreshed;
    if (refresh) {
      refreshed = await refreshForCheck(
        request: request,
        name: name!,
        report: report,
        timeout: refreshTimeout,
        poll: poll,
        restart: restart,
      );
      if (!deepEqual(version, sourceVersion())) throw const _Unavailable('Source changed during refresh; run it again');
      report['stage'] = 'check';
    }
    final requiresBackend = scene['backend'] != null || checks.any((c) => c['kind'] == 'backend_equals');
    profileNeedsBackend = requiresBackend;
    markPhase('ownership');
    final initialSupervisor = requiresBackend ? await request('/dev/status') : null;
    final serviceIdentity = requiresBackend ? _backendIdentity(initialSupervisor) : null;
    if (requiresBackend) {
      code['backendAtStart'] = {
        'services': serviceIdentity,
        'scope': 'Observed before preparation/steps; not final backend verification',
      };
    }
    final target = _targetIdentity(initialSupervisor?['target'], present: _own(initialSupervisor, 'target'));
    if (target != null) report['target'] = target;
    if (journey) {
      try {
        lease = await transport('/journey/lease', {'operation': 'acquire', 'name': name});
      } on Object {
        throw const _Unavailable('Cannot acquire exclusive journey ownership; inspect moments status');
      }
      if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch('${lease['id'] ?? ''}') || lease['phase'] != 'active') {
        throw const _Unavailable('Supervisor did not grant exclusive journey ownership');
      }
      lastHeartbeat = nowMs();
      report['ownership'] = {'id': lease['id'], 'phase': lease['phase']};
    }
    markPhase('preparationAndRestoration');
    final opened =
        inherited ??
        refreshed?.snapshot ??
        await request(
          '/moments/open',
          journey ? {'name': name, 'fresh': true, 'prepare': true} : {'name': name, 'prepare': false},
        );
    if ((opened['state'] as Map?)?['name'] != name) throw const _Unavailable('Unexpected Moment opened');
    Object? expected = (opened['state']! as Map)['projection'];
    final revision = opened['revision'];
    final deadline = nowMs() + timeout;
    Map<String, Object?> look;
    while (true) {
      look = await request('/moments/look');
      assertActor(look);
      if (look['revision'] != revision || (look['state'] as Map?)?['name'] != name) {
        throw const _Unavailable('Moment changed during the check');
      }
      if ((look['observed'] as Map?)?['revision'] == revision) break;
      if (nowMs() >= deadline) throw const _Unavailable('Flutter did not confirm restoration before the deadline');
      await _sleep(poll);
    }
    var first = asObject(look['observed']);
    if (first['client'] is! String || (first['client'] as String).isEmpty || first['projection'] == null) {
      throw const _Unavailable('Flutter report has no runtime identity or projection');
    }
    if (look['codeChanged'] == true) throw const _Unavailable('Apply the current Dart source before checking');
    assertDartRuntime(look['dart']);
    void validateInspection(Map<String, Object?> inspection) {
      assertDartRuntime((inspection['moment'] as Map?)?['dart']);
      if (!deepEqual(version, sourceVersion())) {
        throw const _Unavailable('Source changed while awaiting the gesture outcome');
      }
      final supervisor = inspection['supervisor'] as Map?;
      if (requiresBackend &&
          (!deepEqual(serviceIdentity, _backendIdentity(supervisor)) ||
              !deepEqual(target, _targetIdentity(supervisor?['target'], present: _own(supervisor, 'target'))))) {
        throw const _Unavailable('Backend source, process or target changed while awaiting the gesture outcome');
      }
    }

    Future<Object?> settle() async {
      final captured = await request('/moments/settle', {'revision': revision, 'client': first['client']});
      final sequence = captured['sequence'];
      if (captured['status'] != 'captured' ||
          captured['name'] != name ||
          captured['revision'] != revision ||
          captured['client'] != first['client'] ||
          sequence is! int ||
          sequence < 1 ||
          !RegExp(r'^[-a-f0-9]{36}$').hasMatch('${captured['id'] ?? ''}')) {
        throw const _Unavailable('Runtime did not confirm a fresh persisted UI capture');
      }
      final current = await request('/moments/look');
      final inspection = await request('/moments/inspect');
      validateInspection(inspection);
      final observed = current['observed'] as Map?;
      final lastReported = (inspection['screen'] as Map?)?['lastReported'] as Map?;
      if (current['revision'] != revision ||
          (current['state'] as Map?)?['name'] != name ||
          current['codeChanged'] == true ||
          observed?['client'] != first['client'] ||
          observed?['revision'] != revision ||
          observed?['captureSequence'] != sequence ||
          observed?['reportedAt'] != captured['reportedAt'] ||
          (inspection['moment'] as Map?)?['revision'] != revision ||
          lastReported?['matchesRevision'] != true ||
          !deepEqual(observed?['projection'], lastReported?['projection'])) {
        throw const _Unavailable('State changed after fresh UI capture');
      }
      assertDartRuntime(current['dart']);
      return captured;
    }

    if (journey) {
      if (!deepEqual(version, sourceVersion())) throw const _Unavailable('Source changed during preparation');
      report['stage'] = 'steps';
      markPhase('steps');
      await executeSteps(
        scene: scene,
        request: request,
        revision: revision,
        client: first['client'],
        expected: expected,
        properties: properties,
        evaluate: evaluateChecks,
        report: report,
        validateInspection: validateInspection,
        settle: navigation ? settle : null,
      );
      report['stage'] = 'check';
    }
    if (navigation) {
      report['stage'] = 'capture';
      report['capture'] = await settle();
      report['status'] = 'captured';
      report['verification'] =
          ((report['steps'] as List?) ?? const []).cast<Map>().any(
            (step) => (step['checks'] as List?)?.isNotEmpty ?? false,
          )
          ? 'step-criteria-only'
          : 'not-performed';
      report['skippedFinalCriteria'] = [
        for (final c in checks)
          if (c['scope'] != 'step') c['name'],
      ];
      if (requiresBackend) {
        code['backend'] = {
          'services': serviceIdentity,
          'scope': 'Owned backend identity checked during capture; no business criteria evaluated',
        };
      }
    } else {
      markPhase('verification');
      final finalChecks = checks.where((c) => c['scope'] != 'step').toList();
      final settlementStarted = nowMs(), settlementDeadline = settlementStarted + timeout;
      finalObservationStarted = settlementStarted;
      final finalObservation = <String, Object?>{'attempts': 0, 'timeoutMs': timeout, 'status': 'waiting'};
      if (journey) report['finalObservation'] = finalObservation;
      while (true) {
        if (journey) {
          finalObservation['attempts'] = (finalObservation['attempts']! as int) + 1;
          look = await request('/moments/look');
          assertActor(look);
          final observed = look['observed'] as Map?;
          if (look['revision'] != revision ||
              (look['state'] as Map?)?['name'] != name ||
              look['codeChanged'] == true ||
              observed?['client'] != first['client'] ||
              observed?['revision'] != revision) {
            throw const _Unavailable('Runtime changed after journey');
          }
          assertDartRuntime(look['dart']);
          // Legitimate UI updates after the final gesture may still be arriving.
          // The runtime identity is fixed; only its projections may settle.
          expected = (look['state']! as Map)['projection'];
          first = asObject(observed);
        }
        final inspection = await request('/moments/inspect');
        final last = await request('/moments/look');
        assertActor(last);
        assertDartRuntime(last['dart']);
        assertDartRuntime((inspection['moment'] as Map?)?['dart']);
        final observed = last['observed'] as Map?;
        final moment = inspection['moment'] as Map?;
        if (last['revision'] != revision ||
            (last['state'] as Map?)?['name'] != name ||
            observed?['client'] != first['client'] ||
            observed?['revision'] != revision ||
            moment?['revision'] != revision ||
            last['codeChanged'] == true ||
            moment?['codeChanged'] == true ||
            !deepEqual(version, sourceVersion())) {
          throw const _Unavailable('Source or runtime changed during the check; run it again');
        }
        if (requiresBackend) {
          final finalSupervisor = await request('/dev/status');
          final finalIdentity = _backendIdentity(finalSupervisor);
          final inspected = inspection['supervisor'] as Map?;
          if (!deepEqual(
                target,
                _targetIdentity(finalSupervisor['target'], present: _own(finalSupervisor, 'target')),
              ) ||
              !deepEqual(target, _targetIdentity(inspected?['target'], present: _own(inspected, 'target')))) {
            throw const _Unavailable('Flutter target changed during the check');
          }
          if (!deepEqual(serviceIdentity, finalIdentity) || !deepEqual(serviceIdentity, _backendIdentity(inspected))) {
            throw const _Unavailable('Backend source or process changed during the check; run it again');
          }
          code['backend'] = {
            'services': serviceIdentity,
            'scope':
                'Declared service sources applied to owned live processes; not a database snapshot or deployment attestation',
          };
        }
        final lastReported = (inspection['screen'] as Map?)?['lastReported'] as Map?;
        final stable =
            lastReported?['matchesRevision'] == true &&
            deepEqual(expected, (last['state']! as Map)['projection']) &&
            deepEqual(first['projection'], observed!['projection']) &&
            deepEqual(observed['projection'], lastReported!['projection']);
        if (!stable && !journey) throw const _Unavailable('State changed during the check; run it again');
        final outcomes = stable
            ? evaluateChecks(
                finalChecks,
                expected: expected,
                observed: observed['projection'],
                backend: inspection['backend'],
                properties: properties,
              )
            : <Map<String, Object?>>[];
        report['checks'] = outcomes;
        report['status'] = !stable || outcomes.any((c) => c['status'] == 'unavailable')
            ? 'unavailable'
            : outcomes.any((c) => c['status'] == 'failed')
            ? 'failed'
            : 'passed';
        report['restoration'] = {
          'revision': revision,
          'reportedAt': observed?['reportedAt'],
          'elapsedMs': nowMs() - started,
        };
        if (refreshed != null) {
          final supervisor = await request('/dev/status');
          if (supervisor['id'] != refreshed.id ||
              supervisor['phase'] != 'ready' ||
              supervisor['pending'] == true ||
              supervisor['held'] == true) {
            throw const _Unavailable('Another refresh or edit started during the check');
          }
        }
        if (!journey) break;
        finalObservation['durationMs'] = nowMs() - settlementStarted;
        finalObservation['status'] = report['status'];
        if (report['status'] == 'passed') break;
        if (nowMs() >= settlementDeadline) {
          report['reason'] = stable
              ? 'Final journey criteria were not reached before the deadline'
              : 'UI did not settle before the final journey deadline';
          break;
        }
        // Retry observations only. Preparation and gestures remain exactly once.
        await _sleep(poll);
      }
    }
  } on Object catch (error, stack) {
    if (Platform.environment['MOMENTS_DEBUG'] != null) stderr.writeln('$error\n$stack');
    if (report['finalObservation'] case final Map<String, Object?> observation) {
      report['checks'] = <Object?>[];
      observation['status'] = 'unavailable';
      observation['durationMs'] = nowMs() - (finalObservationStarted ?? started);
      report.remove('restoration');
      (report['code'] as Map?)?.remove('backend');
    }
    report['status'] = switch (error) {
      RefreshCheckError(:final status) || JourneyError(:final status) => status,
      _ => 'unavailable',
    };
    report['reason'] = switch (error) {
      _Unavailable(:final message) ||
      DeclarationSourceError(:final message) ||
      RefreshCheckError(:final message) ||
      JourneyError(:final message) ||
      MomentsError(:final message) => message,
      _ => 'Unable to read the declaration or contact/inspect the local Moment runtime',
    };
  } finally {
    markPhase('finalization');
    if (lease?['id'] case final String id) {
      try {
        report['actions'] = actionEvidence(
          await transport('/journey/actions?journeyId=$id'),
          ((report['steps'] as List?) ?? const []).cast<Map<String, Object?>>(),
          id,
        );
      } on Object {
        report['actions'] = {
          'status': 'unavailable',
          'coverage': 'not-established',
          'reason': 'Action receipts unavailable; no inference about unobserved actions',
        };
      }
      try {
        final passed = const ['passed', 'captured'].contains(report['status']);
        final ended = await transport('/journey/lease', {'operation': 'finish', 'journeyId': id, 'passed': passed});
        report['ownership'] = {'id': id, 'phase': ended['phase']};
        if (passed && ended['phase'] != 'idle') throw StateError('Ownership was not released');
      } on Object {
        report['status'] = 'unavailable';
        report['reason'] = 'Journey ownership could not be released; inspect moments status before recovery';
        report['ownership'] = {'id': id, 'phase': 'unknown'};
      }
    }
  }
  report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
  report['durationMs'] = nowMs() - started;
  markPhase(null);
  if (profile) report['profile'] = journeyProfile(report, requiresBackend: profileNeedsBackend);
  if (report['status'] != 'captured') {
    report['verdict'] = avpVerdict(
      subject: name ?? 'active',
      status: report['status']! as String,
      checks: (report['checks']! as List).cast<Map<String, Object?>>(),
      reason: report['reason'] as String?,
    );
  }
  final directory = Directory(p.join(project, 'moments/.proofs'));
  if (!directory.existsSync()) {
    directory.createSync(recursive: true);
    Process.runSync('chmod', ['700', directory.path]);
  }
  final file = p.join(
    directory.path,
    '${(report['startedAt']! as String).replaceAll(RegExp('[:.]'), '-')}-${report['id']}.json',
  );
  final handle = openPrivate('$file.tmp');
  try {
    handle.writeStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  } finally {
    handle.closeSync();
  }
  File('$file.tmp').renameSync(file);
  final status = report['status']! as String;
  final actions = report['actions'] as Map?;
  final receipts = (actions?['receipts'] as List?)?.cast<Map>();
  return {
    'status': status,
    'exitCode': status == 'passed' && (report['profile'] as Map?)?['status'] == 'partial'
        ? 2
        : const {'passed': 0, 'captured': 0, 'failed': 1, 'unavailable': 2}[status],
    'report': file,
    'checks': [
      for (final c in (report['checks']! as List).cast<Map>()) {'name': c['name'], 'status': c['status']},
    ],
    'reason': ?report['reason'],
    'verdict': ?report['verdict'],
    'durationMs': report['durationMs'],
    if (profile) 'profile': report['profile'],
    if (actions != null)
      'actions': {
        'status': actions['status'],
        'coverage': 'not-established',
        'requests': receipts?.length ?? 0,
        'spans': receipts?.fold<int>(0, (sum, r) => sum + (r['actions'] as List).length) ?? 0,
        'truncated': actions['overflow'] == true || (receipts?.any((r) => r['truncated'] == true) ?? false),
        'changes': [
          for (final r in receipts ?? const <Map>[])
            for (final c in (r['changes'] as List?)?.cast<Map>() ?? const <Map>[])
              '${c['resource']}#${c['subject']} ${c['action']} ${c['outcome']}: ${(c['fields'] as List).join(', ')}',
        ],
      },
    if (report['target'] != null) 'target': report['target'],
    if (report['materialization'] != null) 'materialization': report['materialization'],
    if (navigation) ...{
      'operation': report['operation'],
      'verification': report['verification'],
      'capture': report['capture'],
      'skippedFinalCriteria': report['skippedFinalCriteria'],
    },
    if (refresh) ...{'name': name, 'stage': report['stage'], 'refresh': report['refresh']},
    if (journey) ...{
      'name': name,
      'stage': report['stage'],
      'steps': report['steps'] ?? <Object?>[],
      'ownership': report['ownership'],
      'finalObservation': report['finalObservation'],
    },
  };
}
