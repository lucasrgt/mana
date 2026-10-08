import 'package:path/path.dart' as p;

import 'declaration_sources.dart';
import 'json.dart';
import 'projection.dart';

Map<String, Object?> _pick(Object? value, Iterable<String> keys) => {
  if (value is Map)
    for (final key in keys)
      if (value.containsKey(key)) key: value[key],
};

Map<String, Object?> _ashSource(Object? source, Object? declaration, Object? project) {
  if (source is! Map) return {'status': 'unavailable', 'reason': 'No Ash source metadata; run moments sync.'};
  final file = source['file'], line = source['line'], module = source['module'], sha = source['sha256'];
  if (declaration is! String ||
      file is! String ||
      p.isAbsolute(file) ||
      !RegExp(r'\.exs?$').hasMatch(file) ||
      line is! int ||
      line < 1 ||
      module is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha is String ? sha : '')) {
    return {'status': 'unavailable', 'reason': 'Invalid Ash source metadata; run moments sync.'};
  }
  final location = {'file': p.normalize(p.join(p.dirname(declaration), file)), 'line': line, 'module': module};
  try {
    final root = project is String ? project : p.normalize(p.join(p.dirname(declaration), '..'));
    final current = declarationSource(root, declaration, source)['sha256'];
    return {
      ...location,
      'status': current == sha ? 'current' : 'stale',
      if (current != sha) 'reason': 'Ash source changed since export; run moments sync before trusting this line.',
    };
  } on Object {
    return {...location, 'status': 'unavailable', 'reason': 'Ash source file is unavailable locally.'};
  }
}

/// A view of the existing inspection, not a checker or a new observation.
/// Saved state, reported UI and backend evidence stay distinguishable.
Map<String, Object?> compactInspection(Map<String, Object?> full, Map<String, Object?> manifest) {
  final moment = (full['moment'] as Map?)?.cast<String, Object?>();
  final scene = (manifest['moments'] as Map?)?[moment?['name']] as Map?;
  final route = (moment?['savedProjection'] as Map?)?['route'];
  final declared = scene != null && (scene['projection'] as Map?)?['route'] == route;
  final contract = !declared
      ? null
      : manifest['screens'] != null
      ? (manifest['screens'] as Map)[route] as Map?
      : manifest;
  final scoped = contract != null && contract['watch'] is List;
  final checks = scoped && scene!['checks'] is List ? scene['checks'] as List : const <Object?>[];
  final reported = ((full['screen'] as Map?)?['lastReported'] as Map?)?.cast<String, Object?>();
  final properties = (contract?['properties'] as Map?)?.cast<String, Object?>();
  final projection = (reported?['projection'] as Map?)?.cast<String, Object?>();
  final matchesSaved =
      reported != null && deepEqual(restorableProjection(projection ?? {}, properties), moment?['savedProjection']);
  final observations = reported != null && properties != null
      ? _pick(projection, properties.keys.where((key) => (properties[key] as Map?)?['restore'] == false))
      : <String, Object?>{};
  final lastReported = reported != null
      ? {
          ..._pick(reported, const ['reportedAt', 'ageMs', 'matchesRevision']),
          'matchesSaved': matchesSaved,
          if (observations.isNotEmpty) 'observations': observations,
          if (!matchesSaved) 'projection': projection,
        }
      : null;
  final fields = {
    for (final check in checks)
      if (check is Map && check['kind'] == 'backend_equals')
        for (final field in [check['field'], check['match']])
          if (field is String && field.isNotEmpty) field,
  };
  final backend = full['backend'] as Map?;
  final sources = full['sources'] as Map?;
  return {
    'version': 1,
    'view': 'active-moment',
    'project': full['project'],
    'inspectedAt': full['inspectedAt'],
    'moment': moment != null ? {...moment, if (declared) 'description': scene['description']} : null,
    'screen': {
      ..._pick(full['screen'], const ['status', 'liveness']),
      'lastReported': lastReported,
    },
    'backend': {
      ..._pick(backend, const ['status', 'source', 'observedAt', 'reason', 'recipe', 'base']),
      if (fields.isNotEmpty && backend?['projection'] != null) 'projection': _pick(backend!['projection'], fields),
    },
    'sources': {
      'declaration': sources?['declaration'],
      'watched': scoped ? contract['watch'] : const <Object?>[],
      'scope': 'active-screen',
      'ash': _ashSource(scoped ? scene!['source'] : null, sources?['declaration'], full['project']),
      if (!scoped)
        'issue': moment != null
            ? 'Active Moment has no matching screen declaration; use --full for raw context.'
            : 'No active Moment.',
    },
    'criteria': {
      'status': !scoped
          ? 'unavailable'
          : checks.isNotEmpty
          ? 'declared'
          : 'none',
      'executed': false,
      'items': checks,
    },
    if (full['supervisor'] != null)
      'supervisor': _pick(full['supervisor'], const ['phase', 'id', 'pending', 'held', 'error', 'target']),
  };
}
