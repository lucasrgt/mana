import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart'
    show databaseDocker, findOwnedDatabase, savePrivateState, syncDirectory, validateDatabaseIdentity;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'lifecycle.dart';

Map<String, Object?>? _read(String file) =>
    File(file).existsSync() ? (jsonDecode(File(file).readAsStringSync()) as Map).cast() : null;

/// Explicit discard of this isolated database. A durable intent makes a
/// second reset safe after death between Docker removal and local metadata
/// cleanup.
Future<Map<String, Object?>> resetInstance(String project, {bool discardData = false}) async {
  if (!discardData) throw const MomentsError('Reset removes local data; use moments reset --discard-data explicitly');
  final directory = p.join(project, 'moments', '.backend');
  if (!Directory(directory).existsSync()) throw const MomentsError('No local instance to reset');
  return withInstanceLock(directory, () async {
    assertNoManagedSession(directory);
    if (File(p.join(directory, 'running.json')).existsSync()) {
      throw const MomentsError('Stop or recover this execution with moments down before reset');
    }
    final manifest = p.join(directory, 'instance.json'), intentFile = p.join(directory, '.reset.json');
    final instance = _read(manifest);
    final workspace = workspaceIdentity(project);
    var intent = _read(intentFile);
    if (intent != null &&
        (intent['version'] != 1 ||
            intent['workspace'] != workspace ||
            intent['operation'] != 'discard-local-database' ||
            !intent.containsKey('databaseWorkspace') ||
            (intent['databaseWorkspace'] != null && intent['databaseWorkspace'] != workspace))) {
      throw const MomentsError('Invalid reset ownership');
    }
    if (intent == null && instance == null) throw const MomentsError('No local instance to reset');
    if (instance != null) {
      validateDatabaseIdentity(instance);
      if (instance['workspace'] != null && instance['workspace'] != workspace)
        throw const MomentsError('Instance belongs to another workspace');
      if (intent != null && (intent['id'] != instance['id'] || intent['container'] != instance['container'])) {
        throw const MomentsError('Database identity changed during reset');
      }
      if (intent != null && intent['databaseWorkspace'] != instance['workspace']) {
        throw const MomentsError('Database ownership changed during reset');
      }
    }
    final identity =
        instance ??
        {
          'id': intent!['id'],
          'container': intent['container'],
          if (intent['databaseWorkspace'] != null) 'workspace': intent['databaseWorkspace'],
        };
    validateDatabaseIdentity(identity);
    final container = findOwnedDatabase(
      identity,
      allowAbsent: intent != null || instance?['databasePhase'] == 'creating',
    );
    if ((container?['State'] as Map?)?['Running'] == true) {
      throw const MomentsError('Database is still running; use moments down before reset');
    }
    if (intent == null) {
      intent = {
        'version': 1,
        'operation': 'discard-local-database',
        'workspace': workspace,
        'id': instance!['id'],
        'container': instance['container'],
        // Legacy databases only carried owner; do not claim new labels for them.
        'databaseWorkspace': instance['workspace'],
        'recordedAt': DateTime.now().toUtc().toIso8601String(),
      };
      savePrivateState(intentFile, intent);
    }
    if (container != null) databaseDocker(['rm', '-v', container['Id']! as String]);
    // Use the original identity rules even when instance.json was already removed.
    final expected = {
      'id': intent['id'],
      'container': intent['container'],
      if (intent['databaseWorkspace'] != null) 'workspace': intent['databaseWorkspace'],
    };
    if (findOwnedDatabase(expected, allowAbsent: true) != null)
      throw const MomentsError('Database still exists after reset');
    final proofs = Directory(p.join(project, 'moments', '.proofs', 'resets'))..createSync(recursive: true);
    final proof = p.join(proofs.path, '${intent['id']}.json');
    if (!File(proof).existsSync()) {
      savePrivateState(proof, {
        'version': 1,
        'instanceId': intent['id'],
        'discardedAt': DateTime.now().toUtc().toIso8601String(),
        'preparation': instance?['preparation'],
        'basePhase': instance?['phase'],
        'effects': 'owned database removed; external effects not rolled back',
      });
    }
    for (final file in ['instance.json', 'ui-session.json', '.journey.json', '.runtime.json', '.defines.json']) {
      final path = File(p.join(directory, file));
      if (path.existsSync()) path.deleteSync();
    }
    syncDirectory(directory);
    File(intentFile).deleteSync();
    syncDirectory(directory);
    return {
      'status': 'reset',
      'instanceId': intent['id'],
      'discarded': 'owned-local-database',
      'proofsPreserved': true,
    };
  });
}
