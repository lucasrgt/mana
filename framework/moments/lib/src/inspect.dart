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
  Development? development,
}) async {
  final context = moments.inspect();
  final now = DateTime.now();
  final state = context['state'] as Map?;
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
  final renewal = development?.renewal;
  final commands = {
    'list': ['list'],
    'open': ['open', '<name>'],
    if (name != null) ...{
      'fresh': ['open', name, '--fresh'],
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
    'sources': {'declaration': context['declaration'], 'watched': context['watch']},
    'catalog': context['catalog'],
    if (development != null) ...{'supervisor': development.status(), 'renewal': renewal?.status()},
    'cli': momentsCommand(project),
    'commands': commands,
  };
}
