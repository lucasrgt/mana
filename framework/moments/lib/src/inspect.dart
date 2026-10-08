import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'live_source.dart';
import 'runtime.dart';
import 'suite.dart' show selfCommand;

/// What the bridge's development side offers `/moments/inspect` and
/// `/dev/*`: the supervisor status, an owned backend probe, refresh and stop.
abstract interface class Development {
  Map<String, Object?> status();
  Future<Map<String, Object?>> Function()? get inspect;
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh;
  Future<void> Function()? get stop;
  Renewal? get renewal;
}

abstract interface class Renewal {
  Map<String, Object?> status();
  Map<String, Object?> start(Object? name);
  bool canRenew(String name);
}

/// The command a person runs to drive this runtime by hand.
List<String> momentsCommand(String project) => [...selfCommand(), '--project', project];

Future<Map<String, Object?>> inspectMoment({
  required String project,
  required Moments moments,
  required Map<String, Object?> schema,
  required Map<String, Object?> values,
  required String revision,
  required List<Map<String, Object?>> acknowledgments,
  Development? development,
}) async {
  final context = moments.inspect();
  final now = DateTime.now();
  final targetsFile = File(p.join(project, 'live-ui/targets.json'));
  final targets = targetsFile.existsSync()
      ? (jsonDecode(targetsFile.readAsStringSync()) as Map).cast<String, Object?>()
      : <String, Object?>{};
  final properties = <String, Object?>{};
  final state = context['state'] as Map?;
  final prefix = context['liveUiPrefix'] as String?;
  if (state != null && prefix != null) {
    for (final MapEntry(:key, value: rule) in schema.entries.where((e) => e.key.startsWith(prefix))) {
      final target = targets[key] as Map?;
      final property = <String, Object?>{
        ...(rule! as Map).cast<String, Object?>(),
        'override': values[key],
        'source': target,
      };
      try {
        property['sourceDefault'] = readDefault(project, target!.cast());
      } on Object {
        property['sourceDefault'] = null;
        property['issue'] = 'Source binding unavailable; inspect the mapped file';
      }
      property['configuredValue'] = property['override'] ?? property['sourceDefault'];
      properties[key] = property;
    }
  }
  Map<String, Object?> backend = {'status': 'not-configured'};
  final probe = development?.inspect;
  if (probe != null) {
    try {
      backend = await probe();
    } on Object {
      backend = {
        'status': 'unavailable',
        'observedAt': DateTime.now().toUtc().toIso8601String(),
        'reason': 'Could not inspect the owned backend; check the launcher and Docker.',
      };
    }
  }
  final name = state?['name'] as String?;
  final scope = prefix != null ? ['--prefix', prefix] : const <String>[];
  final renewal = development?.renewal;
  final commands = {
    'list': ['list'],
    'open': ['open', '<name>'],
    if (name != null) ...{
      'fresh': ['open', name, '--fresh'],
      'resetUi': ['live', 'reset', '--wait'],
      'patch': ['live', 'patch', '<json>', '--wait'],
      'review': ['live', 'incorporate', ...scope],
      'incorporate': ['live', 'incorporate', '--write', ...scope],
    },
    if (development != null) ...{
      'refresh': ['refresh'],
      'supervisor': ['status'],
    },
    if (renewal != null && name != null && renewal.canRenew(name)) 'renew': ['renew', name],
  };
  final observed = context['observed'] as Map?;
  return {
    'version': 1,
    'project': project,
    'inspectedAt': now.toUtc().toIso8601String(),
    'moment': state != null
        ? {
            'name': name,
            'revision': context['revision'],
            'savedProjection': state['projection'],
            'backend': context['backend'],
            'dart': context['dart'],
            'codeChanged': context['codeChanged'],
            'sourceIssue': context['sourceIssue'],
            'recipeChanged': context['recipeChanged'],
          }
        : null,
    'screen': {
      'status': name == null
          ? 'idle'
          : observed == null
          ? 'awaiting-runtime'
          : 'last-reported',
      'lastReported': observed != null
          ? {
              'projection': observed['projection'],
              'reportedAt': observed['reportedAt'],
              'ageMs': now
                  .difference(DateTime.parse(observed['reportedAt']! as String))
                  .inMilliseconds
                  .clamp(0, 1 << 62),
              'matchesRevision': observed['revision'] == context['revision'],
            }
          : null,
      'liveness': 'not-probed',
    },
    'backend': backend,
    'editing': {
      'revision': revision,
      'properties': properties,
      'previewAcknowledged': acknowledgments.any((ack) => ack['revision'] == revision),
      'valueMeaning': 'Source defaults plus saved overrides; not values read from rendered widgets.',
    },
    'sources': {'declaration': context['declaration'], 'watched': context['watch']},
    'catalog': context['catalog'],
    if (development != null) ...{'supervisor': development.status(), 'renewal': renewal?.status()},
    'cli': momentsCommand(project),
    'commands': commands,
  };
}
