import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mana/mana.dart'
    show Instance, assertOwned, identityJson, processIdentity, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'layers.dart';
import 'lifecycle.dart';
import 'private_fs.dart';

/// `docker` with optional standard input; the injected form allows real
/// interrupted-command proofs.
typedef PostgresDocker = Future<String> Function(List<String> args, {String? input});

Future<String> postgresDocker(List<String> args, {String? input}) async {
  final child = await Process.start('docker', args);
  if (input != null) child.stdin.write(input);
  await child.stdin.close();
  final out = child.stdout.transform(utf8.decoder).join(), err = child.stderr.drain<void>();
  final code = await child.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      child.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  await err;
  if (code != 0) throw const MomentsError('Owned database operation failed; local preparation state was preserved');
  return (await out).trim();
}

final _identifier = RegExp(r'^[a-z][a-z0-9_]{0,62}$');

String _quoted(String value) {
  if (!_identifier.hasMatch(value)) throw const MomentsError('Invalid database name');
  return '"$value"';
}

String _hex(int bytes) {
  final random = Random.secure();
  return [for (var i = 0; i < bytes; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

Map<String, Object?> _privateRecord(String file) => readJsonObject(file, 16384, 'Invalid database ownership record');

/// Copies databases inside the owned cluster with TEMPLATE. Each copy has its
/// own NOLOGIN owner role and an identity comment, so recovery only ever drops
/// what this driver created.
final class PostgresLayer implements LayerDriver {
  PostgresLayer({PostgresDocker docker = postgresDocker}) : _transport = docker;

  final PostgresDocker _transport;

  @override
  String get type => 'postgres';

  String _cluster(Instance instance) {
    final actual = assertOwned(instance);
    if ((actual['State'] as Map?)?['Running'] != true) throw const MomentsError('Owned database cluster is stopped');
    return actual['Id']! as String;
  }

  Future<String> _sql(
    Instance instance,
    String text, {
    String? token,
    String database = 'postgres',
    bool secret = false,
  }) {
    _quoted(database);
    return _transport([
      'exec',
      if (secret) '-i',
      if (token != null) ...['-e', 'PGAPPNAME=moments-layer-$token'],
      instance['container']! as String,
      'psql',
      '-X',
      '-qAt',
      '-v',
      'ON_ERROR_STOP=1',
      '-U',
      'postgres',
      '-d',
      database,
      if (!secret) ...['-c', text],
    ], input: secret ? text : null);
  }

  Future<void> _assertIdle(Instance instance, String name) async {
    _quoted(name);
    if (await _sql(instance, "SELECT count(*) FROM pg_stat_activity WHERE datname='$name'") != '0') {
      throw const MomentsError('Database layer has active connections; quiesce its runtime');
    }
  }

  Future<Map<String, Object?>?> _metadata(Instance instance, String name, {bool optional = false}) async {
    _quoted(name);
    final value = await _sql(
      instance,
      "SELECT json_build_object('oid',oid::bigint,'ownerOid',datdba::bigint,'connections',datallowconn,'comment',shobj_description(oid,'pg_database')) FROM pg_database WHERE datname='$name'",
    );
    if (value.isEmpty) {
      if (optional) return null;
      throw const MomentsError('Database layer is missing');
    }
    return (jsonDecode(value) as Map).cast();
  }

  static String _marker(Instance instance, Map<String, Object?> handle) =>
      'moments:${instance['id']}:${handle['token']}';

  static void _shape(Map<String, Object?> handle) {
    final token = handle['token'];
    final suffix = token is String ? token.replaceAll('-', '') : '';
    bool optionalOid(Object? value) => value == null || (value is int && value >= 1);
    if (!const [2, 3].contains(handle['version']) ||
        !const ['snapshot', 'branch'].contains(handle['kind']) ||
        !isUuid(token) ||
        handle['database'] != 'moments_${handle['kind'] == 'snapshot' ? 's' : 'b'}_$suffix' ||
        handle['role'] != 'moments_o_$suffix' ||
        !optionalOid(handle['oid']) ||
        !optionalOid(handle['roleOid'])) {
      throw const MomentsError('Invalid recoverable database handle');
    }
  }

  Future<Map<String, Object?>?> _roleMetadata(Instance instance, Map<String, Object?> handle) async {
    final value = await _sql(
      instance,
      "SELECT json_build_object('oid',oid::bigint,'login',rolcanlogin,'superuser',rolsuper,'createDb',rolcreatedb,'createRole',rolcreaterole,'replication',rolreplication,'bypassRls',rolbypassrls,'memberships',(SELECT count(*) FROM pg_auth_members WHERE member=pg_roles.oid),'comment',shobj_description(oid,'pg_authid')) FROM pg_roles WHERE rolname='${handle['role']}'",
    );
    if (value.isEmpty) return null;
    final role = (jsonDecode(value) as Map).cast<String, Object?>();
    final v3 = handle['version'] == 3;
    if ((role['login'] == true && !(v3 && handle['kind'] == 'branch')) ||
        role['comment'] != _marker(instance, handle) ||
        (handle['roleOid'] != null && role['oid'] != handle['roleOid']) ||
        (v3 &&
            (role['superuser'] == true ||
                role['createDb'] == true ||
                role['createRole'] == true ||
                role['replication'] == true ||
                role['bypassRls'] == true ||
                role['memberships'] != 0))) {
      throw const MomentsError('Database owner role identity changed');
    }
    return role;
  }

  Future<Map<String, Object?>> _validate(
    Instance instance,
    Map<String, Object?> handle, {
    bool owned = false,
    bool snapshot = false,
  }) async {
    final oid = handle['oid'];
    if (!const [1, 2, 3].contains(handle['version']) ||
        !_identifier.hasMatch('${handle['database'] ?? ''}') ||
        oid is! int ||
        oid < 1 ||
        !const ['source', 'snapshot', 'branch'].contains(handle['kind'])) {
      throw const MomentsError('Invalid database layer handle');
    }
    if (handle['cluster'] != _cluster(instance) || handle['owner'] != instance['id']) {
      throw const MomentsError('Database layer belongs to another cluster');
    }
    if (owned && (!const ['snapshot', 'branch'].contains(handle['kind']) || !isUuid(handle['token']))) {
      throw const MomentsError('Only a driver-owned copy may be disposed');
    }
    final current = (await _metadata(instance, handle['database']! as String))!;
    if (current['oid'] != oid) throw const MomentsError('Database layer identity changed');
    if (handle['kind'] != 'source' && current['comment'] != _marker(instance, handle)) {
      throw const MomentsError('Database copy ownership changed');
    }
    if ((handle['version']! as int) >= 2) {
      _shape(handle);
      final role = await _roleMetadata(instance, handle);
      if (role == null || current['ownerOid'] != role['oid']) throw const MomentsError('Database copy owner changed');
    }
    if (snapshot && (handle['kind'] != 'snapshot' || current['connections'] == true)) {
      throw const MomentsError('Expected a sealed database snapshot');
    }
    return current;
  }

  /// The application database a preparation captured from.
  Future<LayerHandle> sourceHandle(Instance instance, String database) async {
    final identity = _cluster(instance), value = (await _metadata(instance, database))!;
    return {
      'version': 1,
      'kind': 'source',
      'owner': instance['id'],
      'cluster': identity,
      'database': database,
      'oid': value['oid'],
    };
  }

  Future<Map<String, Object?>> _cleanup(
    Instance instance,
    Map<String, Object?> handle, [
    void Function(Map<String, Object?> pinned)? pin,
  ]) async {
    _shape(handle);
    if (handle['cluster'] != _cluster(instance) || handle['owner'] != instance['id']) {
      throw const MomentsError('Database layer belongs to another cluster');
    }
    if (await _sql(
          instance,
          "SELECT count(*) FROM pg_stat_activity WHERE application_name='moments-layer-${handle['token']}'",
        ) !=
        '0') {
      throw const MomentsError('Database layer operation is still in flight');
    }
    final role = await _roleMetadata(instance, handle);
    final current = await _metadata(instance, handle['database']! as String, optional: true);
    if (current != null) {
      if (role == null ||
          current['ownerOid'] != role['oid'] ||
          (handle['oid'] != null && current['oid'] != handle['oid']) ||
          (current['comment'] != null && current['comment'] != _marker(instance, handle))) {
        throw const MomentsError('Database copy identity changed; recovery refused');
      }
      // Pin identifiers before DROP, including a CREATE whose reply was lost.
      handle = {...handle, 'oid': current['oid'], 'roleOid': role['oid']};
      pin?.call(handle);
      await _assertIdle(instance, handle['database']! as String);
      await _sql(instance, 'DROP DATABASE ${_quoted(handle['database']! as String)}');
    }
    // DROP ROLE refuses any other dependencies. Never reassign or cascade them.
    // If CREATE DATABASE is still arriving, its owner dependency either blocks
    // this drop or its missing owner makes CREATE fail; no usable orphan starts.
    if (role != null) await _sql(instance, 'DROP ROLE ${_quoted(handle['role']! as String)}');
    return handle;
  }

  Future<LayerHandle> _createCopy(
    Instance instance,
    Map<String, Object?> source,
    String out,
    String kind,
    ({List<String> schemas, int connectionLimit})? access,
  ) async {
    if (access != null &&
        (access.schemas.isEmpty ||
            access.schemas.length > 16 ||
            access.schemas.toSet().length != access.schemas.length ||
            access.schemas.any((s) => !_identifier.hasMatch(s) || s.startsWith('pg_') || s == 'information_schema') ||
            access.connectionLimit < 1 ||
            access.connectionLimit > 64)) {
      throw const MomentsError('Declare runtime schemas and a bounded connection limit');
    }
    await _validate(instance, source, snapshot: source['kind'] == 'snapshot');
    await _assertIdle(instance, source['database']! as String);
    makePrivateDirectory(out, recursive: true);
    final record = p.join(out, 'database.json'), intent = p.join(out, 'intent.json');
    const occupied = MomentsError('Database layer destination is occupied; inspect it instead of replaying creation');
    if (exists(record) || exists(intent)) throw occupied;
    final token = uuidV4(), suffix = token.replaceAll('-', '');
    final supervisor = processIdentity(pid);
    if (supervisor == null) throw const MomentsError('Cannot identify database layer supervisor');
    var state = <String, Object?>{
      'version': access != null && kind == 'branch' ? 3 : 2,
      'kind': kind,
      'owner': instance['id'],
      'cluster': source['cluster'],
      'database': 'moments_${kind == 'snapshot' ? 's' : 'b'}_$suffix',
      'role': 'moments_o_$suffix',
      'token': token,
      'source': {'database': source['database'], 'oid': source['oid']},
      'supervisor': identityJson(supervisor),
      'phase': 'creating',
    };
    try {
      createExclusive(intent, utf8.encode('${jsonEncode(state)}\n'));
    } on FileSystemException {
      throw occupied;
    }
    syncDirectory(out);
    final database = state['database']! as String, role = state['role']! as String;
    try {
      // The role and its identity marker commit atomically before CREATE DATABASE.
      await _sql(
        instance,
        "BEGIN; CREATE ROLE ${_quoted(role)} NOLOGIN; COMMENT ON ROLE ${_quoted(role)} IS '${_marker(instance, state)}'; COMMIT",
        token: token,
      );
      state = {...state, 'roleOid': (await _roleMetadata(instance, state))!['oid']};
      savePrivateState(intent, state);
      // Every new database is initially sealed, including branches.
      await _sql(
        instance,
        'CREATE DATABASE ${_quoted(database)} OWNER ${_quoted(role)} TEMPLATE ${_quoted(source['database']! as String)} ALLOW_CONNECTIONS false',
        token: token,
      );
      state = {...state, 'oid': (await _metadata(instance, database))!['oid']};
      savePrivateState(intent, state);
      await _sql(
        instance,
        "REVOKE CONNECT ON DATABASE ${_quoted(database)} FROM PUBLIC; COMMENT ON DATABASE ${_quoted(database)} IS '${_marker(instance, state)}'${kind == 'branch' ? '; ALTER DATABASE ${_quoted(database)} ALLOW_CONNECTIONS true' : ''}",
        token: token,
      );
      if (state['version'] == 3) {
        final credentials = {
          'version': 1,
          'database': database,
          'username': role,
          'password': _hex(32),
          'token': token,
        };
        savePrivateState(p.join(out, 'access.json'), credentials);
        final schemas = access!.schemas.map(_quoted).join(',');
        // Grants survive TEMPLATE copies without depending on a previous actor's
        // ephemeral role. pg_database_owner means the owner of THIS database.
        await _sql(
          instance,
          'BEGIN; GRANT USAGE ON SCHEMA $schemas TO pg_database_owner; GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA $schemas TO pg_database_owner; GRANT USAGE,SELECT,UPDATE ON ALL SEQUENCES IN SCHEMA $schemas TO pg_database_owner; COMMIT',
          token: token,
          database: database,
        );
        await _sql(
          instance,
          "ALTER ROLE ${_quoted(role)} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT ${access.connectionLimit} PASSWORD '${credentials['password']}'",
          token: token,
          secret: true,
        );
      }
      final handle = {
        for (final MapEntry(:key, :value) in state.entries)
          if (!const ['source', 'supervisor', 'phase'].contains(key)) key: value,
      };
      savePrivateState(record, handle);
      savePrivateState(intent, {...state, 'phase': 'ready'});
      return handle;
    } on Object {
      savePrivateState(intent, {...state, 'phase': 'attention'});
      rethrow;
    }
  }

  static Instance _instance(LayerOptions opts) =>
      opts.instance ?? (throw const MomentsError('The Postgres layer needs the owned database instance'));

  @override
  Future<void> capture({
    required LayerHandle handle,
    required String out,
    LayerOptions opts = const LayerOptions(),
  }) async {
    await _createCopy(_instance(opts), handle, out, 'snapshot', null);
  }

  @override
  Future<LayerHandle> materialize({
    required String dir,
    required String from,
    LayerOptions opts = const LayerOptions(),
  }) async {
    final instance = _instance(opts);
    final source = _privateRecord(p.join(from, 'database.json'));
    await _validate(instance, source, snapshot: true);
    return _createCopy(instance, source, dir, 'branch', opts.runtimeAccess);
  }

  /// The dedicated login of a version-3 branch for its actor's backend.
  Future<({String database, String username, String password})> runtimeAccess({
    required LayerHandle handle,
    required String dir,
    LayerOptions opts = const LayerOptions(),
  }) async {
    final instance = _instance(opts);
    if (handle['version'] != 3 || handle['kind'] != 'branch') {
      throw const MomentsError('Actor runtime requires a branch with dedicated database credentials');
    }
    await _validate(instance, handle, owned: true);
    if ((await _roleMetadata(instance, handle))?['login'] != true) {
      throw const MomentsError('Actor database login is not ready');
    }
    final file = p.join(dir, 'access.json');
    if (!private(file)) throw const MomentsError('Actor database credentials must be private');
    final value = _privateRecord(file);
    if (value['version'] != 1 ||
        value['database'] != handle['database'] ||
        value['username'] != handle['role'] ||
        value['token'] != handle['token'] ||
        !sha256Pattern.hasMatch('${value['password'] ?? ''}')) {
      throw const MomentsError('Actor database credential identity changed');
    }
    return (
      database: value['database']! as String,
      username: value['username']! as String,
      password: value['password']! as String,
    );
  }

  @override
  Future<void> dispose({required LayerHandle handle, LayerOptions opts = const LayerOptions()}) async {
    final instance = _instance(opts);
    if ((handle['version'] as int? ?? 0) >= 2) {
      await _cleanup(instance, handle);
      return;
    }
    // Existing v1 copies retain their original OID/comment checks.
    await _validate(instance, handle, owned: true);
    await _assertIdle(instance, handle['database']! as String);
    await _sql(instance, 'DROP DATABASE ${_quoted(handle['database']! as String)}');
  }

  @override
  Future<void> forget({required String dir, LayerOptions opts = const LayerOptions()}) async {
    final handle = _privateRecord(p.join(dir, 'database.json'));
    if (handle['kind'] != 'snapshot') throw const MomentsError('Expected snapshot ownership');
    await dispose(handle: handle, opts: opts);
  }

  @override
  Future<Map<String, Object?>> recover({
    required String dir,
    LayerOptions opts = const LayerOptions(),
    bool pending = false,
  }) async {
    if (!exists(dir) && pending) return {'status': 'disposed', 'empty': true, 'recipeReplayed': false};
    final instance = _instance(opts);
    return withInstanceLock(dir, () async {
      final file = p.join(dir, 'intent.json');
      if (!exists(file) &&
          pending &&
          Directory(dir).listSync().every((entry) => p.basename(entry.path) == '.operation.lock')) {
        return {'status': 'disposed', 'empty': true, 'recipeReplayed': false};
      }
      var state = _privateRecord(file);
      _shape(state);
      final source = state['source'], supervisor = state['supervisor'];
      if (!const ['creating', 'ready', 'attention', 'disposed'].contains(state['phase']) ||
          source is! Map ||
          !_identifier.hasMatch('${source['database'] ?? ''}') ||
          source['oid'] is! int ||
          (source['oid']! as int) < 1 ||
          source['database'] == state['database'] ||
          supervisor is! Map ||
          supervisor['pid'] is! int ||
          (supervisor['pid']! as int) < 1 ||
          !RegExp(r'^\d+$').hasMatch('${supervisor['start'] ?? ''}') ||
          !isUuid(supervisor['boot'])) {
        throw const MomentsError('Invalid database recovery intent');
      }
      if (sameProcess(supervisor.cast()) && !(state['phase'] == 'attention' && supervisor['pid'] == pid)) {
        throw const MomentsError('Database layer supervisor is alive; stop it before recovery');
      }
      state = await _cleanup(instance, state, (pinned) {
        state = pinned;
        savePrivateState(file, state);
      });
      savePrivateState(file, {...state, 'phase': 'disposed'});
      return {'status': 'disposed', 'database': state['database'], 'recipeReplayed': false};
    });
  }
}
