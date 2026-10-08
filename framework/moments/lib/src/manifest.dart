import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'graph.dart';
import 'protocol.dart';

typedef Manifest = Map<String, Object?>;

Manifest validateManifest(Manifest manifest) {
  final version = manifest['version'];
  final moments = manifest['moments'];
  if (![1, 2, 3].contains(version) ||
      (version == 2 ? manifest['screens'] : manifest['properties'] ?? manifest['screens']) == null ||
      manifest['watch'] is! List ||
      moments is! Map ||
      moments.isEmpty) {
    throw const MomentsError('Invalid Moments manifest; run moment sync');
  }
  validateLineage(moments);
  final declared = manifest['protocol'] as Map?;
  if (version == 3 && protocol.entries.any((entry) => declared?[entry.key] != entry.value)) {
    throw const MomentsError('Unsupported Moments protocol/profile');
  }
  if (version != 3 && moments.values.any((scene) => (scene as Map)['from'] != null)) {
    throw const MomentsError('Moment lineage requires manifest version 3; run moment sync');
  }
  return manifest;
}

/// The manifest with `recipeHash`: the digest of its exact bytes, never of a
/// re-serialization.
Manifest readManifest(String file) {
  final bytes = File(file).readAsBytesSync();
  final manifest = validateManifest((jsonDecode(utf8.decode(bytes)) as Map).cast());
  return {...manifest, 'recipeHash': sha256.convert(bytes).toString()};
}

List<Map<String, Object?>> manifestCatalog(String file) => [
  for (final MapEntry(key: name, value: scene) in (readManifest(file)['moments']! as Map).entries)
    {'name': name, 'from': (scene as Map)['from'], 'description': scene['description'], 'executor': 'backend-sandbox'},
];
