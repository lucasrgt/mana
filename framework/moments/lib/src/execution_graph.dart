import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'graph.dart';
import 'protocol.dart';

final _uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
final _hash = RegExp(r'^[a-f0-9]{64}$');

bool _uuidOk(Object? value) => value is String && _uuid.hasMatch(value);

void _require(bool condition, String message) {
  if (!condition) throw MomentsError('Invalid materialization journal: $message');
}

/// A read-only projection of a pinned declaration and recorded lifecycle
/// events. Not a second graph definition, a liveness probe or a verification run.
Map<String, Object?> executionGraph(Map<String, Object?> manifest, List<Object?> events) {
  final moments = (manifest['moments']! as Map).cast<String, Object?>();
  final graph = momentGraph(moments);
  final first = events.isEmpty ? null : events.first;
  _require(first is Map && first['type'] == 'run.started', 'missing run identity');
  first as Map;
  _require(
    first['manifest'] is String &&
        _hash.hasMatch(first['manifest'] as String) &&
        first['manifest'] == manifest['recipeHash'],
    'declaration changed',
  );
  _require(first['code'] is String && _hash.hasMatch(first['code'] as String), 'missing code identity');
  _require(
    protocol.entries.every((entry) => (first['protocol'] as Map?)?[entry.key] == entry.value),
    'unsupported protocol',
  );
  _require(
    _uuidOk(first['runId']) && first['scope'] is String && (first['scope'] as String).isNotEmpty,
    'missing run scope',
  );
  final instances = <String, Map<String, Object?>>{},
      snapshots = <String, Map<String, Object?>>{},
      transitions = <String, Map<String, Object?>>{};
  var end = 'incomplete';
  Object? parentOf(Object? moment) => (moments[moment] as Map?)?['from'];
  for (final (index, raw) in events.indexed) {
    _require(raw is Map, 'malformed record');
    final event = raw! as Map;
    _require(event['version'] == 1 && event['sequence'] == index + 1, 'noncontiguous sequence');
    _require(event['runId'] == first['runId'] && event['scope'] == first['scope'], 'mixed runs or scopes');
    _require(event['at'] is String && DateTime.tryParse(event['at'] as String) != null, 'missing event time');
    _require(end != 'closed', 'events after cleanup completed');
    if (index == 0) {
      _require(event.containsKey('moment') && event['moment'] == null, 'run has a Moment');
      continue;
    }
    if (const ['closed', 'cleanup.failed'].contains(event['type'])) {
      _require(event.containsKey('moment') && event['moment'] == null, 'cleanup has a Moment');
      if (event['type'] == 'closed') {
        _require(instances.values.every((i) => i['phase'] == 'disposed'), 'cleanup before disposal');
      }
      end = event['type']! as String;
      continue;
    }
    _require(moments.containsKey(event['moment']), 'unknown Moment');
    _require(_uuidOk(event['instanceId']), 'missing instance identity');
    var instance = instances[event['instanceId']];
    if (event['type'] == 'materialization.started') {
      _require(instance == null, 'duplicate instance');
      final parent = parentOf(event['moment']);
      if (event['fromSnapshot'] != null) {
        final snapshot = snapshots[event['fromSnapshot']];
        _require(snapshot?['phase'] == 'ready', 'source snapshot not ready');
        _require(snapshot!['moment'] == event['materializedMoment'], 'source Moment mismatch');
        _require([event['moment'], parent].contains(snapshot['moment']), 'source outside declared lineage');
      } else {
        _require(
          event.containsKey('fromSnapshot') && parent == null && event['materializedMoment'] == null,
          'child without a parent snapshot',
        );
      }
      instance = {
        'id': event['instanceId'],
        'moment': event['moment'],
        'materializedMoment': event['materializedMoment'],
        'fromSnapshot': event['fromSnapshot'],
        'phase': 'materializing',
        'lastSequence': event['sequence'],
      };
      instances[event['instanceId']! as String] = instance;
      continue;
    }
    _require(instance != null && instance['moment'] == event['moment'], 'event without matching instance');
    instance!;
    _require(instance['phase'] != 'disposed', 'event after instance disposal');
    switch (event['type']) {
      case 'layers.materialized':
        _require(
          instance['phase'] == 'materializing' &&
              event['materializedMoment'] == instance['materializedMoment'] &&
              event['fromSnapshot'] == instance['fromSnapshot'],
          'layer source mismatch',
        );
        instance['phase'] = 'layers-ready';
      case 'runtime.ready':
        _require(
          instance['phase'] == 'layers-ready' && event['materializedMoment'] == instance['materializedMoment'],
          'runtime before layers',
        );
        instance['phase'] = 'ready';
      case 'transition.started':
        final parent = parentOf(event['moment']);
        _require(
          instance['phase'] == 'ready' && instance['materializedMoment'] == parent && event['from'] == parent,
          'transition outside declared edge',
        );
        _require(
          _uuidOk(event['transitionId']) && !transitions.containsKey(event['transitionId']),
          'duplicate or missing transition',
        );
        transitions[event['transitionId']! as String] = {
          'id': event['transitionId'],
          'instanceId': instance['id'],
          'from': parent,
          'to': event['moment'],
          'status': 'started',
          'startedAt': event['at'],
        };
        instance['phase'] = 'transitioning';
      case 'transition.completed':
        final transition = transitions[event['transitionId']];
        _require(
          instance['phase'] == 'transitioning' &&
              transition?['instanceId'] == instance['id'] &&
              transition!['status'] == 'started' &&
              transition['from'] == event['from'],
          'completion without matching transition',
        );
        transition!['status'] = 'completed';
        transition['completedAt'] = event['at'];
        instance['materializedMoment'] = event['moment'];
        instance['phase'] = 'transition-completed';
      case 'runtime.stopped':
        _require(
          const ['ready', 'transition-completed', 'attention'].contains(instance['phase']),
          'stop without runtime',
        );
        instance['phase'] = 'stopped';
      case 'capture.started':
        _require(
          instance['phase'] == 'stopped' && instance['materializedMoment'] == event['moment'],
          'capture before completed transition and stop',
        );
        _require(
          _uuidOk(event['snapshotId']) && !snapshots.containsKey(event['snapshotId']),
          'duplicate or missing snapshot',
        );
        snapshots[event['snapshotId']! as String] = {
          'id': event['snapshotId'],
          'moment': event['moment'],
          'instanceId': instance['id'],
          'phase': 'capturing',
        };
      case 'snapshot.ready':
        final snapshot = snapshots[event['snapshotId']];
        _require(
          instance['phase'] == 'stopped' &&
              snapshot?['instanceId'] == instance['id'] &&
              snapshot!['phase'] == 'capturing',
          'snapshot without capture',
        );
        snapshot!['phase'] = 'ready';
        snapshot['capturedAt'] = event['at'];
      case 'materialization.failed' || 'build.failed':
        instance['phase'] = 'attention';
        for (final transition in transitions.values) {
          if (transition['instanceId'] == instance['id'] && transition['status'] == 'started') {
            transition['status'] = 'failed';
          }
        }
      case 'instance.disposed':
        _require(
          const ['stopped', 'attention', 'materializing', 'layers-ready'].contains(instance['phase']),
          'dispose before runtime stop',
        );
        instance['phase'] = 'disposed';
      default:
        throw const MomentsError('Invalid materialization journal: unsupported event type');
    }
    instance['lastSequence'] = event['sequence'];
  }
  final recorded = transitions.values.toList();
  return {
    ...graph,
    'kind': 'execution-map',
    'nodes': [
      for (final node in graph['nodes']! as List)
        {
          ...(node as Map).cast<String, Object?>(),
          'evidence': {
            'snapshots': [
              for (final s in snapshots.values)
                if (s['moment'] == node['name'] && s['phase'] == 'ready') s['id'],
            ],
            'transitions': [
              for (final t in recorded)
                if (t['to'] == node['name']) t['id'],
            ],
            'verification': 'not-recorded',
          },
        },
    ],
    'edges': [
      for (final edge in graph['edges']! as List)
        {
          ...(edge as Map).cast<String, Object?>(),
          'transitions': [
            for (final t in recorded)
              if (t['from'] == edge['from'] && t['to'] == edge['to']) t['id'],
          ],
        },
    ],
    'execution': {
      'runId': first['runId'],
      'scope': first['scope'],
      'manifest': first['manifest'],
      'code': first['code'],
      'currentCodeComparison': 'not-performed',
      'observedThrough': (events.last! as Map)['at'],
      'lastSequence': events.length,
      'phaseAtLastEvent': end,
      'liveState': 'not-probed',
      'verification': 'not-recorded',
      'instances': instances.values.toList(),
      'snapshots': snapshots.values.toList(),
      'transitions': recorded,
    },
  };
}

Map<String, Object?> readExecutionGraph(Map<String, Object?> manifest, String file) {
  _require(File(file).lengthSync() <= 16 * 1024 * 1024, 'journal exceeds read limit');
  final text = File(file).readAsStringSync();
  _require(text.endsWith('\n'), 'incomplete last record');
  final List<Object?> events;
  try {
    events = [for (final line in text.trimRight().split('\n')) jsonDecode(line)];
  } on FormatException {
    throw const MomentsError('Invalid materialization journal: malformed record');
  }
  return executionGraph(manifest, events);
}
