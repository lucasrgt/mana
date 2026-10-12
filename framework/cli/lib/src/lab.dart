import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'elixir.dart';
import 'failure.dart';
import 'manifest.dart';
import 'sandbox.dart';

/// What a lab run talks to. By default a Moments sandbox, read from its
/// `instance.json`. With `MANA_LAB_POSTGRES` set to the URL of a PostgreSQL
/// server already running on this machine
/// (`postgres://user:password@host:port`), the lab uses that server instead
/// and asks no container engine anything: for a machine that is itself the
/// sandbox, like a dev container or a CI job. `psql` must be installed there.
final class LabDatabase {
  LabDatabase._({
    required this.password,
    required this.jwtSecret,
    required this.webUrl,
    required this.apiUrl,
    required String Function(String database) url,
    required void Function(String database) create,
  }) : _url = url,
       _create = create;

  final String password, jwtSecret, webUrl;
  final String? apiUrl;
  final String Function(String database) _url;
  final void Function(String database) _create;

  /// The URL the backend connects to for [database].
  String url(String database) => _url(database);

  /// Creates [database] when the server does not have it yet.
  void create(String database) => _create(database);

  String get recipeToken => _derived(password, 'moments-recipes');
}

String _derived(String password, String purpose) =>
    Hmac(sha256, utf8.encode(password)).convert(utf8.encode(purpose)).toString();

/// The database of this run: the server `MANA_LAB_POSTGRES` names, or the
/// sandbox whose `instance.json` is [instanceFile].
LabDatabase labDatabase(
  String? instanceFile, {
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (env['MANA_LAB_POSTGRES'] case final server? when server.isNotEmpty) {
    return _localDatabase(server, env);
  }
  if (instanceFile == null || instanceFile.isEmpty) {
    throw const ManaFailure(
      'Set MANA_MOMENTS_INSTANCE to a sandbox instance.json (moments up writes one under <app>/moments/.backend/), or MANA_LAB_POSTGRES to a PostgreSQL server on this machine',
    );
  }
  final instance = readInstance(instanceFile);
  assertOwned(instance);
  final container = instance['container']! as String;
  final password = instance['password']! as String;
  return LabDatabase._(
    password: password,
    jwtSecret: instance['jwtSecret']! as String,
    webUrl: instance['webUrl']! as String,
    apiUrl: instance['apiUrl'] as String?,
    url: (database) =>
        'postgres://postgres:$password@127.0.0.1:${instance['pgPort'] ?? _publishedPort(container)}/$database',
    create: (database) {
      final found = databaseDocker([
        'exec',
        container,
        'psql',
        '-U',
        'postgres',
        '-d',
        'postgres',
        '-Atc',
        "SELECT 1 FROM pg_database WHERE datname='$database'",
      ]);
      if (found != '1') {
        databaseDocker([
          'exec',
          container,
          'createdb',
          '-U',
          'postgres',
          database,
        ]);
      }
    },
  );
}

final _databaseName = RegExp(r'^[a-z_][a-z0-9_]*$');

LabDatabase _localDatabase(String server, Map<String, String> env) {
  final uri = Uri.tryParse(server);
  final password = uri?.userInfo.split(':').skip(1).join(':') ?? '';
  if (uri == null ||
      !const ['postgres', 'postgresql'].contains(uri.scheme) ||
      uri.host.isEmpty ||
      password.isEmpty) {
    throw const ManaFailure(
      'MANA_LAB_POSTGRES must be postgres://user:password@host:port',
    );
  }
  final base = uri.replace(path: '').toString();
  String psql(String statement) {
    final result = Process.runSync('psql', [
      '$base/postgres',
      '-v',
      'ON_ERROR_STOP=1',
      '-Atc',
      statement,
    ]);
    if (result.exitCode != 0) {
      throw const ManaFailure(
        'The PostgreSQL server in MANA_LAB_POSTGRES did not answer psql',
      );
    }
    return (result.stdout as String).trim();
  }

  return LabDatabase._(
    password: password,
    jwtSecret: _derived(password, 'lab-token-signing'),
    webUrl: env['LAB_WEB_ORIGIN'] ?? 'http://127.0.0.1:3000',
    apiUrl: null,
    url: (database) => '$base/$database',
    create: (database) {
      if (!_databaseName.hasMatch(database)) {
        throw const ManaFailure('Invalid lab database name');
      }
      if (psql("SELECT 1 FROM pg_database WHERE datname='$database'") != '1') {
        psql('CREATE DATABASE "$database"');
      }
    },
  );
}

/// The backend against a Moments sandbox's PostgreSQL. `prepare` creates the
/// database and migrates, `serve` runs Phoenix, `test` runs ExUnit on its own
/// database and `mix` runs any task.
///
/// The sandbox is `MANA_MOMENTS_INSTANCE` (or the server in
/// `MANA_LAB_POSTGRES`, see [LabDatabase]), the database is `MANA_DATABASE`
/// (`<backend>_dev` by default, `<backend>_test` for `test`), and the
/// backend is the one `mana.toml` names (`--backend` when there are several).
/// The app reads `LAB_DATABASE_URL`, `LAB_PORT`, `LAB_SECRET_KEY_BASE`,
/// `LAB_TOKEN_SIGNING_SECRET`, `LAB_WEB_ORIGIN(S)`, `LAB_SERVER` and
/// `MOMENTS_RECIPE_TOKEN`. Any other variable named in `MANA_LAB_PASS`
/// (comma-separated) is passed through.
Future<void> lab(String root, List<String> arguments, {String? backend}) async {
  final operation = arguments.firstOrNull;
  if (!const ['prepare', 'serve', 'test', 'mix'].contains(operation)) {
    throw const ManaFailure(
      'Use mana lab [--backend <dir>] prepare|serve|test|mix <args>',
    );
  }
  final server = p.join(root, backend ?? labBackend(root));
  final target = labDatabase(Platform.environment['MANA_MOMENTS_INSTANCE']);
  final name = p.basename(server);
  final database = operation == 'test'
      ? '${name}_test'
      : (Platform.environment['MANA_DATABASE'] ?? '${name}_dev');
  final webUrl = target.webUrl;
  final pass = (Platform.environment['MANA_LAB_PASS'] ?? '')
      .split(',')
      .map((key) => key.trim())
      .where((key) => key.isNotEmpty);
  final environment = {
    'LAB_DATABASE_URL': target.url(database),
    'LAB_SECRET_KEY_BASE': _hex(48),
    'LAB_TOKEN_SIGNING_SECRET': target.jwtSecret,
    'LAB_WEB_ORIGIN': webUrl,
    'LAB_WEB_ORIGINS': [
      webUrl,
      ?Platform.environment['MOMENTS_SUITE_ORIGIN'],
    ].join(','),
    'LAB_PORT':
        '${Uri.parse(target.apiUrl ?? 'http://127.0.0.1:4000').port}',
    'MOMENTS_RECIPE_TOKEN': target.recipeToken,
    'LAB_SERVER': operation == 'serve' ? 'true' : 'false',
    'MIX_ENV': operation == 'test' ? 'test' : 'dev',
    for (final key in pass)
      if (Platform.environment[key] case final value?) key: value,
  };
  Future<void> run(List<String> args) =>
      mix(server, args, environment: environment, hostNetwork: true);
  void createDatabase() => target.create(database);

  switch (operation) {
    case 'prepare':
      createDatabase();
      await run(['ecto.migrate']);
    case 'serve':
      await run(['phx.server']);
    case 'test':
      createDatabase();
      await run(['deps.compile']);
      await run(['ecto.migrate']);
      await run(['test', ...arguments.skip(1)]);
    case 'mix':
      await run(arguments.skip(1).toList());
  }
}

/// The one backend `mana.toml`'s products name.
String labBackend(String root) {
  final products = (readManifest(root)['products'] as Map?) ?? const {};
  final backends = {
    for (final product in products.values.whereType<Map>())
      if (product['backend'] case final String backend) backend,
  };
  if (backends.length != 1) {
    throw ManaFailure(
      backends.isEmpty
          ? 'mana.toml names no backend; pass --backend'
          : 'mana.toml names several backends; pass --backend',
    );
  }
  return backends.single;
}

String _hex(int bytes) {
  final random = Random.secure();
  return [
    for (var i = 0; i < bytes; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

Object _publishedPort(String container) {
  final inspected =
      (jsonDecode(databaseDocker(['inspect', container])) as List).single
          as Map;
  final ports = (inspected['NetworkSettings'] as Map)['Ports'] as Map;
  return ((ports['5432/tcp'] as List).first as Map)['HostPort'] as Object;
}
