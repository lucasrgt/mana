import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'errors.dart';
import 'format.dart';
import 'protocol.dart';

void validateLineage(Object? moments) {
  if (moments is! Map) throw const MomentsError('Invalid Moments catalog');
  final names = moments.keys.cast<String>().toList(), done = <String>{};
  for (final name in names) {
    if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(name)) throw const MomentsError('Invalid Moment name');
    final scene = moments[name];
    if (scene is! Map) throw MomentsError('Invalid Moment: $name');
    final from = scene['from'];
    if (from != null && (from is! String || !moments.containsKey(from))) {
      throw MomentsError('Unknown Moment parent: $name');
    }
  }
  // Iterative: a long valid lineage must not exhaust the call stack.
  for (final name in names) {
    final visiting = <String>{};
    for (
      String? current = name;
      current != null && !done.contains(current);
      current = (moments[current] as Map)['from'] as String?
    ) {
      if (!visiting.add(current)) throw MomentsError('Moment parent cycle: $current');
    }
    done.addAll(visiting);
  }
}

Map<String, Object?> momentGraph(Map<String, Object?> moments) {
  validateLineage(moments);
  final nodes = [
    for (final name in moments.keys.toList()..sort())
      {
        'name': name,
        'from': (moments[name]! as Map)['from'],
        'description': (moments[name]! as Map)['description'] ?? '',
        'state': 'declared',
      },
  ];
  return {
    'version': 1,
    'protocol': protocol,
    'kind': 'declared-map',
    'nodes': nodes,
    'edges': [
      for (final node in nodes)
        if (node['from'] != null) {'from': node['from'], 'to': node['name']},
    ],
    'roots': [
      for (final node in nodes)
        if (node['from'] == null) node['name'],
    ],
    'topologySha256': sha256
        .convert(
          utf8.encode(
            jsonEncode([
              for (final node in nodes) {'name': node['name'], 'from': node['from']},
            ]),
          ),
        )
        .toString(),
    'execution': null,
  };
}

Map<String, Object?> graphFromMap(String text) {
  final map = parseMap(text);
  if (map.meta['moments'] != protocol['version']) throw const MomentsError('Unsupported Moments protocol version');
  return momentGraph({
    for (final MapEntry(key: name, value: scene) in map.states.entries)
      name: {'from': scene.from, 'description': scene.describe},
  });
}
