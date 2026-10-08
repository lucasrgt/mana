import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'failure.dart';

final _uuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);

/// A Moments sandbox's `instance.json`: its database container and secrets.
typedef Instance = Map<String, Object?>;

Instance readInstance(String file) =>
    (jsonDecode(File(file).readAsStringSync()) as Map).cast();

String databaseDocker(
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) {
  final result = Process.runSync('docker', args);
  if (result.exitCode != 0) {
    throw const ManaFailure(
      'Owned database operation failed; local preparation state was preserved',
    );
  }
  return (result.stdout as String).trim();
}

void validateDatabaseIdentity(Instance instance) {
  final id = instance['id'], workspace = instance['workspace'];
  if (id is! String ||
      !_uuid.hasMatch(id) ||
      instance['container'] != 'moments-$id' ||
      (workspace != null &&
          (workspace is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(workspace)))) {
    throw const ManaFailure('Invalid sandbox database identity');
  }
}

/// The inspected database container of [instance], refused unless its name and
/// ownership labels say it belongs to this sandbox.
Map<String, Object?>? findOwnedDatabase(
  Instance instance, {
  bool allowAbsent = false,
}) {
  validateDatabaseIdentity(instance);
  final container = instance['container']! as String;
  final ids = databaseDocker([
    'ps',
    '-aq',
    '--no-trunc',
    '--filter',
    'name=^/$container\$',
  ]).split(RegExp(r'\s+')).where((id) => id.isNotEmpty).toList();
  if (ids.isEmpty) {
    if (allowAbsent) return null;
    throw const ManaFailure(
      'Owned database is missing; inspect or explicitly reset this instance',
    );
  }
  if (ids.length != 1) throw const ManaFailure('Ambiguous database identity');
  final actual =
      ((jsonDecode(databaseDocker(['inspect', ids.single])) as List).single
              as Map)
          .cast<String, Object?>();
  final labels = ((actual['Config']! as Map)['Labels'] as Map?) ?? const {};
  final workspace = instance['workspace'];
  if (actual['Name'] != '/$container' ||
      labels['dev.moments.owner'] != instance['id'] ||
      (workspace != null &&
          (labels['dev.moments.workspace'] != workspace ||
              labels['dev.moments.role'] != 'database'))) {
    throw const ManaFailure(
      'Container does not belong to this Moments database',
    );
  }
  return actual;
}

Map<String, Object?> assertOwned(Instance instance) =>
    findOwnedDatabase(instance)!;

/// The bearer the backend's recipe endpoint expects from this sandbox.
String recipeToken(Instance instance) => Hmac(
  sha256,
  utf8.encode(instance['password']! as String),
).convert(utf8.encode('moments-recipes')).toString();
