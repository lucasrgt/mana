import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show findOwnedDatabase;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'journey_lease.dart';
import 'lifecycle.dart';

/// Operational state read without loading an app adapter or exposing launch data.
Map<String, Object?> inspectInstance(String project) {
  final directory = p.join(project, 'moments', '.backend');
  Map<String, Object?>? read(String name) {
    final file = File(p.join(directory, name));
    return file.existsSync() ? (jsonDecode(file.readAsStringSync()) as Map).cast() : null;
  }

  final instance = read('instance.json'), execution = read('running.json'), reset = read('.reset.json');
  if (instance != null && instance.containsKey('workspace') && instance['workspace'] != workspaceIdentity(project)) {
    throw const MomentsError('Instance belongs to another workspace');
  }
  final live =
      execution != null &&
      sameProcess((validateLifecycle(execution, project)['supervisor'] as Map?)?.cast<String, Object?>());
  final database = instance != null
      ? findOwnedDatabase(instance, allowAbsent: instance['databasePhase'] == 'creating' || reset != null)
      : null;
  final journey = readJourneyState(p.join(directory, '.journey.json'));
  final preparation = (instance?['preparation'] as Map?)?.cast<String, Object?>();
  return {
    'scope': 'local-instance; no app criteria executed',
    'phase': reset != null
        ? 'reset-interrupted'
        : preparation != null
        ? (live ? 'preparing' : 'preparation-incomplete')
        : live
        ? 'running'
        : instance != null
        ? 'stopped'
        : 'absent',
    'instanceId': instance?['id'],
    'supervisor': execution != null ? (live ? 'alive' : 'interrupted') : 'none',
    'database': database != null
        ? ((database['State'] as Map?)?['Running'] == true ? 'running' : 'stopped')
        : instance != null
        ? 'not-created'
        : 'none',
    if (preparation != null)
      'preparation': {
        'moment': preparation['moment'],
        'stage': preparation['stage'],
        'startedAt': preparation['startedAt'],
      },
    'basePhase': instance?['phase'],
    'journey': journey != null
        ? {
            'name': journey['name'],
            'phase': live ? journey['phase'] : 'attention',
            'lastOperation': journey['lastOperation'],
          }
        : null,
  };
}
