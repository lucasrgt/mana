import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart' show Instance, assertOwned, databaseDocker, readInstance, uuidV4;
import 'package:moments/moments.dart';
import 'package:path/path.dart' as p;

final class ProofFailure implements Exception {
  ProofFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

void check(bool condition, String message) {
  if (!condition) throw ProofFailure(message);
}

Future<void> rejects(Future<void> Function() operation, Pattern reason, String label) async {
  try {
    await operation();
  } on MomentsError catch (error) {
    check(error.message.contains(reason), '$label: ${error.message}');
    return;
  }
  throw ProofFailure('$label was not refused');
}

const _contend = '--contend';

/// One of two OS processes racing for the same destination.
Future<void> _contender(String instanceFile, String from, String dir) async {
  try {
    final handle = await PostgresLayer().materialize(
      dir: dir,
      from: from,
      opts: LayerOptions(instance: readInstance(instanceFile)),
    );
    print(jsonEncode({'status': 'created', 'handle': handle}));
  } on Object catch (error) {
    print(jsonEncode({'status': 'refused', 'reason': error is MomentsError ? error.message : 'unexpected'}));
    exitCode = 2;
  }
}

Future<void> main(List<String> args) async {
  if (args.firstOrNull == _contend && args.length == 4) return _contender(args[1], args[2], args[3]);
  if (args.length != 3) {
    stderr.writeln('Usage: prove_postgres_fork.dart <owned-instance.json> <database> <private-proof-directory>');
    exitCode = 64;
    return;
  }
  final instanceFile = p.normalize(p.absolute(args[0])), database = args[1];
  final Instance instance = readInstance(instanceFile);
  assertOwned(instance);
  final directory = p.join(p.normalize(p.absolute(args[2])), uuidV4());
  Directory(directory).createSync(recursive: true);
  Process.runSync('chmod', ['700', directory]);
  final opts = LayerOptions(instance: instance), driver = PostgresLayer();
  final copies = <LayerHandle>[], snapshots = <String>[], timing = <String, double>{};
  final container = instance['container']! as String;

  String query(LayerHandle handle, String text) => databaseDocker([
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
    handle['database']! as String,
    '-c',
    text,
  ]);
  String quote(String name) => '"${name.replaceAll('"', '""')}"';
  Map<String, Object?> fingerprint(LayerHandle handle) {
    final tables = query(
      handle,
      "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1",
    ).split('\n').where((t) => t.isNotEmpty).toList();
    final values = [
      for (final table in tables)
        [
          table,
          query(
            handle,
            "SELECT count(*) || ':' || md5(coalesce(string_agg(row_to_json(t)::text,E'\\n' ORDER BY row_to_json(t)::text),'')) FROM ${table.split('.').map(quote).join('.')} t",
          ),
        ],
    ];
    return {'tables': tables.length, 'sha256': sha256.convert(utf8.encode(jsonEncode(values))).toString()};
  }

  bool same(Map<String, Object?> a, Map<String, Object?> b) => jsonEncode(a) == jsonEncode(b);

  Future<({String dir, LayerHandle handle})> capture(LayerHandle handle, String name) async {
    final out = p.join(directory, name), clock = Stopwatch()..start();
    await driver.capture(handle: handle, out: out, opts: opts);
    snapshots.add(out);
    timing[name] = clock.elapsedMicroseconds / 1000;
    return (
      dir: out,
      handle: (jsonDecode(File(p.join(out, 'database.json')).readAsStringSync()) as Map).cast<String, Object?>(),
    );
  }

  Future<LayerHandle> fork(String from, String name) async {
    final clock = Stopwatch()..start();
    final result = await driver.materialize(dir: p.join(directory, name), from: from, opts: opts);
    copies.add(result);
    timing[name] = clock.elapsedMicroseconds / 1000;
    return result;
  }

  final source = await driver.sourceHandle(instance, database), sourceBefore = fingerprint(source);
  Map<String, Object?>? report;
  Object? failure;
  var cleanupErrors = 0;
  try {
    // Use the real consumer database, including its sessions and Oban queues.
    // The source is only read; the synthetic task lives exclusively in a copy.
    check(int.parse(query(source, 'SELECT count(*) FROM tokens')) > 0, 'real session rows required');
    check(int.parse(query(source, 'SELECT count(*) FROM oban_jobs')) > 0, 'real jobs required');
    await rejects(() => driver.dispose(handle: source, opts: opts), 'driver-owned', 'source disposal');
    final baseline = await capture(source, 'source-snapshot');
    try {
      query(baseline.handle, 'SELECT 1');
      throw ProofFailure('snapshot must refuse connections');
    } on ProofFailure {
      rethrow;
    } on Object {
      // Refused, as a sealed snapshot must.
    }
    final parent = await fork(baseline.dir, 'parent');
    check(same(fingerprint(parent), sourceBefore), 'full persisted source copied');
    final id = uuidV4();
    query(
      parent,
      "INSERT INTO tasks (id,owner_id,title,done,estimate_minutes) VALUES ('$id','40000000-0000-4000-8000-000000000001','Independent branches',false,35)",
    );
    final parentBefore = fingerprint(parent);
    final point = await capture(parent, 'parent-snapshot');
    final a = await fork(point.dir, 'branch-a'), b = await fork(point.dir, 'branch-b');
    // Two OS processes really contend for the same destination. A rejected
    // competitor must not replace the winning handle or create an orphan copy.
    final raceDir = p.join(directory, 'contended-branch');
    Future<Map<String, Object?>> contend() async {
      final result = await Process.run(Platform.resolvedExecutable, [
        Platform.script.toFilePath(),
        _contend,
        instanceFile,
        point.dir,
        raceDir,
      ]);
      try {
        return (jsonDecode(result.stdout as String) as Map).cast();
      } on FormatException {
        throw ProofFailure('Invalid contention receipt');
      }
    }

    final contenders = await Future.wait([contend(), contend()]);
    for (final outcome in contenders) {
      if (outcome['status'] == 'created') copies.add((outcome['handle']! as Map).cast());
    }
    final created = contenders.where((c) => c['status'] == 'created').toList();
    check(created.length == 1, 'exactly one contender creates the branch');
    check(
      '${contenders.firstWhere((c) => c['status'] == 'refused')['reason']}'.contains('occupied'),
      'contender refused as occupied',
    );
    check(same(fingerprint((created.single['handle']! as Map).cast()), parentBefore), 'contended branch copied');

    check(a['database'] != b['database'] && a['oid'] != b['oid'], 'branches share an identity');
    check(same(fingerprint(a), parentBefore) && same(fingerprint(b), parentBefore), 'branches copied the parent');
    final aTokens = query(a, 'SELECT count(*) FROM tokens'), bJobs = query(b, 'SELECT count(*) FROM oban_jobs');
    query(a, "UPDATE tasks SET done=true WHERE id='$id'; DELETE FROM tokens");
    check(query(a, "SELECT done FROM tasks WHERE id='$id'") == 't', 'branch a write');
    check(query(b, "SELECT done FROM tasks WHERE id='$id'") == 'f', 'branch b isolated from a');
    check(query(b, 'SELECT count(*) FROM tokens') == aTokens, 'sessions isolated');
    query(b, "UPDATE tasks SET estimate_minutes=90 WHERE id='$id'; DELETE FROM oban_jobs");
    check(query(a, "SELECT estimate_minutes FROM tasks WHERE id='$id'") == '35', 'branch a isolated from b');
    check(query(a, 'SELECT count(*) FROM oban_jobs') == bJobs, 'jobs isolated');
    check(query(b, "SELECT estimate_minutes FROM tasks WHERE id='$id'") == '90', 'branch b write');
    check(same(fingerprint(parent), parentBefore), 'branches cannot mutate parent');
    check(same(fingerprint(source), sourceBefore), 'original consumer untouched');
    final restored = await fork(point.dir, 'restored-parent');
    check(same(fingerprint(restored), parentBefore), 'same snapshot remains reusable after both branches changed');
    await rejects(
      () => driver.dispose(handle: {...a, 'oid': (a['oid']! as int) + 1}, opts: opts),
      'identity changed',
      'stale identity',
    );
    await rejects(
      () => driver.dispose(handle: {...a, 'token': uuidV4()}, opts: opts),
      RegExp('ownership changed|Invalid recoverable database handle'),
      'stale ownership',
    );
    await rejects(
      () => driver.materialize(dir: p.join(directory, 'branch-a'), from: point.dir, opts: opts),
      'occupied',
      'occupied destination',
    );
    // An active connection is a real process; neither capture nor disposal may
    // terminate it to force a snapshot/drop. The owned probe exits naturally.
    final client = await Process.start('docker', [
      'exec',
      '-e',
      'PGAPPNAME=mana-layer-proof',
      container,
      'psql',
      '-X',
      '-qAt',
      '-U',
      'postgres',
      '-d',
      b['database']! as String,
      '-c',
      'SELECT pg_sleep(8)',
    ]);
    unawaited(client.stdout.drain<void>());
    unawaited(client.stderr.drain<void>());
    var connected = false;
    for (var i = 0; i < 50 && !connected; i++) {
      connected =
          query(
            source,
            "SELECT count(*) FROM pg_stat_activity WHERE datname='${b['database']}' AND application_name='mana-layer-proof'",
          ) ==
          '1';
      if (!connected) await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    check(connected, 'live branch connection required');
    await rejects(
      () => driver.capture(handle: b, out: p.join(directory, 'connected-snapshot'), opts: opts),
      'active connections',
      'connected capture',
    );
    await rejects(() => driver.dispose(handle: b, opts: opts), 'active connections', 'connected disposal');
    check(await client.exitCode == 0, 'snapshot/dispose did not terminate client');
    report = {
      'version': 1,
      'status': 'passed',
      'scope': 'Postgres layer only; no full-situation/Flutter fork claim',
      'source': {
        'instanceId': instance['id'],
        'cluster': source['cluster'],
        'database': database,
        'tables': sourceBefore['tables'],
        'sha256': sourceBefore['sha256'],
      },
      'assertions': [
        'full persisted source copied',
        'sealed snapshot rejects connections',
        'two independent branches',
        'sessions isolated',
        'jobs isolated',
        'parent and original unchanged',
        'parent restored from same snapshot',
        'stale ownership rejected',
        'occupied destination refused',
        'connected source not forcibly captured or dropped',
        'concurrent destination has exactly one creator',
      ],
      'timingMs': timing,
      'driverSha256': sha256
          .convert(
            File(
              p.join(p.dirname(p.dirname(Platform.script.toFilePath())), 'lib/src/postgres_layer.dart'),
            ).readAsBytesSync(),
          )
          .toString(),
    };
  } on Object catch (error) {
    failure = error;
  } finally {
    for (final handle in copies.reversed) {
      try {
        await driver.dispose(handle: handle, opts: opts);
      } on Object {
        cleanupErrors++;
      }
    }
    for (final dir in snapshots.reversed) {
      try {
        await driver.forget(dir: dir, opts: opts);
      } on Object {
        cleanupErrors++;
      }
    }
  }
  if (failure != null || cleanupErrors > 0) {
    final reason = switch (failure) {
      ProofFailure(:final message) || MomentsError(:final message) => message,
      null => 'cleanup',
      _ => 'unexpected error',
    };
    stderr.writeln('Database layer proof/cleanup failed ($reason; $cleanupErrors cleanup errors); inspect $directory');
    exitCode = 1;
    return;
  }
  check(same(fingerprint(source), sourceBefore), 'original consumer untouched after cleanup');
  report!['cleanup'] = 'all driver-owned branches and snapshots disposed; original unchanged';
  final file = p.join(directory, 'report.json');
  File(file).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  Process.runSync('chmod', ['600', file]);
  print(jsonEncode({'status': report['status'], 'scope': report['scope'], 'report': file, 'timingMs': timing}));
}
