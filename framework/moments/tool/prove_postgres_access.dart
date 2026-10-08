// Explicit local proof against a stopped consumer's owned Postgres cluster.
// No app writes in the source; all mutations target disposable copies.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart' show Instance, assertOwned, databaseDocker, readInstance, savePrivateState, uuidV4;
import 'package:moments/moments.dart';
import 'package:path/path.dart' as p;

final class ProofFailure implements Exception {
  ProofFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef Access = ({String database, String username, String password});

void check(bool condition, String message) {
  if (!condition) throw ProofFailure(message);
}

Future<void> main(List<String> args) async {
  final file = p.normalize(p.absolute(args.elementAtOrNull(0) ?? '')), database = args.elementAtOrNull(1) ?? '';
  if (args.length != 2 || !RegExp(r'^[a-z][a-z0-9_]{0,62}$').hasMatch(database)) {
    stderr.writeln('Usage: prove_postgres_access.dart <owned-instance.json> <source-database>');
    exitCode = 64;
    return;
  }
  final Instance instance = readInstance(file);
  assertOwned(instance);
  final directory = p.join(p.dirname(p.dirname(file)), '.proofs/postgres-access', uuidV4());
  Directory(directory).createSync(recursive: true);
  Process.runSync('chmod', ['700', directory]);
  final opts = LayerOptions(instance: instance, runtimeAccess: (schemas: const ['public'], connectionLimit: 12));
  final postgres = PostgresLayer();
  final copies = <LayerHandle>[], snapshots = <String>[], denials = <String>[];
  final container = instance['container']! as String;

  String sql(String db, String text) => databaseDocker([
    'exec',
    container,
    'psql',
    '-X',
    '-qAt',
    '-v',
    'ON_ERROR_STOP=1',
    '-U',
    'postgres',
    '-d',
    db,
    '-c',
    text,
  ]);
  String fingerprint(String db) => sha256
      .convert(
        utf8.encode(
          sql(db, 'SELECT row_to_json(t)::text FROM tasks t ORDER BY id') +
              sql(db, 'SELECT nspname,nspacl::text FROM pg_namespace ORDER BY nspname') +
              sql(
                db,
                "SELECT relname,relacl::text FROM pg_class WHERE relnamespace='public'::regnamespace ORDER BY relname",
              ),
        ),
      )
      .toString();

  ProcessResult query(Access access, String db, String text) {
    try {
      return Process.runSync(
        'docker',
        [
          'exec',
          '-e',
          'PGPASSWORD',
          container,
          'psql',
          '-h',
          '127.0.0.1',
          '-X',
          '-qAt',
          '-v',
          'ON_ERROR_STOP=1',
          '-v',
          'VERBOSITY=verbose',
          '-U',
          access.username,
          '-d',
          db,
          '-c',
          text,
        ],
        environment: {'PGPASSWORD': access.password},
      );
    } on ProcessException {
      throw ProofFailure('Actor SQL transport unavailable');
    }
  }

  String allow(Access access, String db, String text) {
    final result = query(access, db, text);
    check(result.exitCode == 0, 'Own-database SQL failed');
    return (result.stdout as String).trim();
  }

  void deny(Access access, String db, String text, String label) {
    final result = query(access, db, text);
    check(result.exitCode != 0, label);
    check(
      RegExp(r'42501|FATAL:\s+permission denied for database').hasMatch(result.stderr as String),
      '$label must fail on authorization: ${(result.stderr as String).trim()}',
    );
    denials.add(label);
  }

  Future<String> capture(LayerHandle handle, String name) async {
    final dir = p.join(directory, name);
    await postgres.capture(handle: handle, out: dir, opts: opts);
    snapshots.add(dir);
    return dir;
  }

  Future<({LayerHandle handle, String dir, Access access})> branch(String from, String name) async {
    final dir = p.join(directory, name), handle = await postgres.materialize(dir: dir, from: from, opts: opts);
    copies.add(handle);
    return (handle: handle, dir: dir, access: await postgres.runtimeAccess(handle: handle, dir: dir, opts: opts));
  }

  final source = await postgres.sourceHandle(instance, database), before = fingerprint(database);
  Object? failure;
  try {
    final root = await capture(source, 'root'), a = await branch(root, 'a'), b = await branch(root, 'b');
    check(a.access.password != b.access.password && a.access.username != b.access.username, 'Branch logins are shared');
    final aDatabase = a.handle['database']! as String, bDatabase = b.handle['database']! as String;
    check(allow(a.access, aDatabase, 'SELECT current_user') == a.handle['role'], 'Branch login has the wrong role');
    check(
      allow(a.access, aDatabase, 'SELECT count(*) FROM tasks') == sql(database, 'SELECT count(*) FROM tasks'),
      'Branch did not copy the source tasks',
    );
    final id = uuidV4();
    allow(
      a.access,
      aDatabase,
      "INSERT INTO tasks (id,owner_id,title,done,estimate_minutes) VALUES ('$id','40000000-0000-4000-8000-000000000001','Scoped actor SQL',false,35)",
    );
    deny(a.access, bDatabase, 'SELECT count(*) FROM tasks', 'sibling connection');
    deny(a.access, database, 'SELECT count(*) FROM tasks', 'source task read');
    deny(a.access, aDatabase, 'SET ROLE postgres', 'administrator role');
    deny(a.access, aDatabase, "SELECT pg_read_file('PG_VERSION')", 'server file read');
    deny(a.access, aDatabase, 'BEGIN; CREATE ROLE moments_forbidden_probe; ROLLBACK', 'role creation');
    final point = await capture(a.handle, 'point'), child = await branch(point, 'child');
    final childDatabase = child.handle['database']! as String;
    check(
      allow(child.access, childDatabase, "SELECT title FROM tasks WHERE id='$id'") == 'Scoped actor SQL',
      'Descendant lost the parent write',
    );
    deny(a.access, childDatabase, 'SELECT 1', 'descendant connection');
    await postgres.dispose(handle: a.handle, opts: opts);
    copies.remove(a.handle);
    // A snapshot/descendant must not retain ACL dependencies on the dead parent role.
    check(
      allow(child.access, childDatabase, "SELECT count(*) FROM tasks WHERE id='$id'") == '1',
      'Descendant depends on the disposed parent role',
    );
    final interrupted = p.join(directory, 'interrupted');
    var lost = false;
    final faulty = PostgresLayer(
      docker: (args, {input}) async {
        final result = await postgresDocker(args, input: input);
        if (!lost && (input?.startsWith('ALTER ROLE') ?? false)) {
          lost = true;
          throw ProofFailure('Lost login grant acknowledgment');
        }
        return result;
      },
    );
    try {
      await faulty.materialize(dir: interrupted, from: root, opts: opts);
      throw ProofFailure('Interrupted login grant was not reported');
    } on ProofFailure catch (error) {
      if (!error.message.contains('Lost login')) rethrow;
    }
    check(lost, 'Login grant was never attempted');
    check(
      (await faulty.recover(dir: interrupted, opts: opts, pending: true))['status'] == 'disposed',
      'Interrupted copy kept',
    );
    check(fingerprint(database) == before, 'Source database changed');
  } on Object catch (error) {
    failure = error;
  }
  var errors = 0;
  for (final handle in copies.reversed) {
    try {
      await postgres.dispose(handle: handle, opts: opts);
    } on Object {
      errors++;
    }
  }
  for (final dir in snapshots.reversed) {
    try {
      await postgres.forget(dir: dir, opts: opts);
    } on Object {
      errors++;
    }
  }
  final report = {
    'status': failure != null || errors > 0 ? 'failed' : 'passed',
    'scope':
        'Postgres 16, public schema, owned local consumer. Native per-branch login and database/table privileges; not OS/network containment.',
    'denials': denials,
    'sourceUnchanged': fingerprint(database) == before,
    'cleanupErrors': errors,
    'reason': switch (failure) {
      null => null,
      ProofFailure(:final message) || MomentsError(:final message) => message,
      _ => 'Proof failed',
    },
    'directory': directory,
  };
  savePrivateState(p.join(directory, 'report.json'), report);
  print(jsonEncode(report));
  if (failure != null || errors > 0) exitCode = 1;
}
