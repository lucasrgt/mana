import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show databaseDocker, findOwnedDatabase;
import 'package:moments/src/errors.dart';
import 'package:moments/src/instance_state.dart';
import 'package:moments/src/lifecycle.dart';
import 'package:moments/src/reset.dart';
import 'package:path/path.dart' as p;

/// Runs one instance operation against `args[1]` and prints `{ok, value}` or
/// `{ok: false, error}`, so tests can substitute `docker` through PATH.
Future<void> main(List<String> args) async {
  final project = args[1];
  try {
    final Object? value = switch (args.first) {
      'inspect' => inspectInstance(project),
      'reset' => await resetInstance(project),
      'discard' => await resetInstance(project, discardData: true),
      'find' => findOwnedDatabase(
        (jsonDecode(File(p.join(project, 'moments/.backend/instance.json')).readAsStringSync()) as Map).cast(),
      ),
      'lifecycle' => Lifecycle.create(project: project, directory: p.join(project, 'moments/.backend')).state,
      'docker' => databaseDocker(['run', '-e', 'POSTGRES_PASSWORD=PRIVATE-INPUT']),
      _ => throw StateError('Unknown operation'),
    };
    stdout.write(jsonEncode({'ok': true, 'value': value}));
  } on Object catch (error) {
    stdout.write(jsonEncode({'ok': false, 'error': error is MomentsError ? error.message : '$error'}));
  }
  exit(0);
}
