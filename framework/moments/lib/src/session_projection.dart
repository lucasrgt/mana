// Read-only compatibility of retained presentation. No database, recipes or
// runtime writes; callers check before invoking app-owned preparation.
import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'json.dart';
import 'projection.dart';

typedef SavedMoments = ({Map<String, Map<String, Object?>> states, Map<String, Object?>? state});

SavedMoments readSavedMoments(String file, Map<String, Object?> contract) {
  final saved = File(file).existsSync() ? jsonDecode(File(file).readAsStringSync()) as Map<String, Object?>? : null;
  final version = saved?['version'];
  if (version != null && version != 2) throw const MomentsError('Unsupported Moments session version');
  if (version == 2 && (saved!['states'] is! Map || !(saved['states'] as Map).containsKey(saved['active']))) {
    throw const MomentsError('Invalid Moments session');
  }
  // The unversioned legacy format stored just the active projection. Import it;
  // the next successful write atomically upgrades the complete session.
  final raw = <String, Object?>{
    if (version == 2)
      ...(saved!['states'] as Map).cast<String, Object?>()
    else if (saved != null)
      saved['name'] as String: saved,
  };
  final states = <String, Map<String, Object?>>{};
  for (final MapEntry(key: name, value: entry) in raw.entries) {
    if (entry is! Map || entry['name'] != name) throw const MomentsError('Invalid saved moment');
    final projection = (entry['projection'] as Map?)?.cast<String, Object?>() ?? const {};
    states[name] = {
      ...entry.cast<String, Object?>(),
      'projection': restorableProjection(projection, propertiesFor(contract, projection['route'])),
    };
  }
  final state = version == 2 ? states[saved!['active']] : (saved != null ? states[saved['name']] : null);
  return (states: states, state: state);
}

bool _isInteger(Object? value) =>
    value is int || (value is double && value == value.truncateToDouble() && value.isFinite);

Map<String, Object?> validateProjection(Map<String, Object?> contract, Object? projection, {bool restoring = false}) {
  if (contract['properties'] != null || contract['screens'] != null) {
    final route = projection is Map ? projection['route'] : null;
    final properties = propertiesFor(contract, route);
    if (properties == null) throw const MomentsError('Route is not enabled for Moments');
    final required = properties.keys.where((key) => !restoring || (properties[key] as Map)['restore'] != false);
    if (projection is! Map ||
        projection.keys.any((key) => !properties.containsKey(key)) ||
        required.any((key) => !projection.containsKey(key))) {
      throw const MomentsError('Unexpected screen state properties');
    }
    for (final MapEntry(:key, value: raw) in properties.entries) {
      final rule = (raw! as Map).cast<String, Object?>();
      if (restoring && rule['restore'] == false) continue;
      final value = projection[key];
      final allowed = rule['enum'] as List?;
      if (allowed != null && !allowed.contains(value)) throw MomentsError('Unsupported $key');
      switch (rule['type']) {
        case 'string':
          if (value is! String || value.length > (rule['maxLength']! as num)) throw MomentsError('Invalid $key');
        case 'object':
          final values = (rule['values']! as Map).cast<String, Object?>();
          if (value is! Map ||
              value.length > (rule['maxProperties']! as num) ||
              value.entries.any(
                (e) =>
                    (e.key as String).length > (rule['keyMaxLength']! as num) ||
                    !_isInteger(e.value) ||
                    (e.value as num) < (values['min']! as num) ||
                    (e.value as num) > (values['max']! as num),
              )) {
            throw MomentsError('Invalid $key');
          }
        case 'number':
          if (value is! num || !value.isFinite || value < (rule['min']! as num) || value > (rule['max']! as num)) {
            throw MomentsError('Invalid $key');
          }
      }
    }
    final copy = jsonCopy(projection.cast<String, Object?>());
    return restoring ? restorableProjection(copy, properties) : copy;
  }
  const draftKeys = ['route', 'fields', 'focus', 'selection'];
  if (projection is! Map || projection.keys.any((key) => !draftKeys.contains(key))) {
    throw const MomentsError('Unknown draft property');
  }
  if (!(contract['routes']! as List).contains(projection['route'])) {
    throw const MomentsError('Route is not enabled for Moments');
  }
  final fields = projection['fields'];
  if (fields is! Map) throw const MomentsError('Expected draft fields');
  final declared = (contract['fields']! as Map).cast<String, Object?>();
  if (!jsonEqual(fields.keys.cast<String>().toList()..sort(), declared.keys.toList()..sort())) {
    throw const MomentsError('Only declared draft fields may be saved');
  }
  for (final MapEntry(:key, :value) in fields.entries) {
    if (value is! String || value.length > ((declared[key]! as Map)['maxLength']! as num)) {
      throw MomentsError('Invalid draft field: $key');
    }
  }
  if (!(contract['focus']! as List).contains(projection['focus'])) throw const MomentsError('Unsupported focus');
  final selection = projection['selection'];
  final length = (fields[projection['focus']] as String?)?.length ?? 0;
  if (selection is! List ||
      selection.length != 2 ||
      selection.any((n) => !_isInteger(n) || (n as num) < 0 || n > length)) {
    throw const MomentsError('Invalid selection');
  }
  return jsonCopy(projection.cast<String, Object?>());
}

Map<String, Object?> resumeProjection(
  Map<String, Object?> contract,
  Map<String, Object?> remembered,
  Map<String, Object?> recipe,
) {
  // Additive declarations may introduce explicit defaults. Preserve every old
  // value; removed fields, routes/types outside the current contract and
  // malformed captures still fail validation. Observations are never input.
  final rememberedProjection = (remembered['projection'] as Map?)?.cast<String, Object?>();
  final recipeProjection = (recipe['projection']! as Map).cast<String, Object?>();
  final compatible =
      remembered['recipeHash'] is String &&
      remembered['recipeHash'] != recipe['recipeHash'] &&
      rememberedProjection?['route'] == recipeProjection['route'];
  return validateProjection(
    contract,
    compatible ? {...recipeProjection, ...?rememberedProjection} : rememberedProjection,
    restoring: true,
  );
}

void validateSavedOpening(
  Map<String, Object?> contract,
  String file,
  String name, {
  bool fresh = false,
  bool resume = true,
}) {
  final (:states, state: _) = readSavedMoments(file, contract);
  final moments = (contract['moments']! as Map).cast<String, Object?>();
  if (!moments.containsKey(name)) throw MomentsError('Unknown moment: $name');
  final recipe = {
    'name': name,
    'recipeHash': contract['recipeHash'],
    'projection': validateProjection(contract, (moments[name]! as Map)['projection'], restoring: true),
  };
  final remembered = !fresh && resume ? states[name] : null;
  if (remembered != null) resumeProjection(contract, remembered, recipe);
}
