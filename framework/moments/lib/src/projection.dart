// Observations travel from the app to Moments only. They are never restore
// input. Absent metadata keeps older contracts fully restorable.

Map<String, Object?>? propertiesFor(Map<String, Object?> manifest, Object? route) {
  final screens = manifest['screens'] as Map?;
  final screen = route is String ? (screens?[route] as Map?) : null;
  return ((screen?['properties'] ?? manifest['properties']) as Map?)?.cast<String, Object?>();
}

Map<String, Object?> restorableProjection(Map<String, Object?> projection, Map<String, Object?>? properties) => {
  for (final MapEntry(:key, :value) in projection.entries)
    if ((properties?[key] as Map?)?['restore'] != false) key: value,
};
