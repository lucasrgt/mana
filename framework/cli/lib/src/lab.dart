import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'elixir.dart';
import 'failure.dart';
import 'manifest.dart';
import 'sandbox.dart';

/// The backend against a Moments sandbox's PostgreSQL. `prepare` creates the
/// database and migrates, `serve` runs Phoenix, `test` runs ExUnit on its own
/// database and `mix` runs any task.
///
/// The sandbox is `MANA_MOMENTS_INSTANCE`, the database is `MANA_DATABASE`
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
  final instanceFile = Platform.environment['MANA_MOMENTS_INSTANCE'];
  if (instanceFile == null || instanceFile.isEmpty) {
    throw const ManaFailure(
      'Set MANA_MOMENTS_INSTANCE to a sandbox instance.json (moments up writes one under <app>/moments/.backend/)',
    );
  }
  final instance = readInstance(instanceFile);
  assertOwned(instance);
  final name = p.basename(server);
  final database = operation == 'test'
      ? '${name}_test'
      : (Platform.environment['MANA_DATABASE'] ?? '${name}_dev');
  final pgPort =
      instance['pgPort'] ?? _publishedPort(instance['container']! as String);
  final webUrl = instance['webUrl']! as String;
  final pass = (Platform.environment['MANA_LAB_PASS'] ?? '')
      .split(',')
      .map((key) => key.trim())
      .where((key) => key.isNotEmpty);
  final environment = {
    'LAB_DATABASE_URL':
        'postgres://postgres:${instance['password']}@127.0.0.1:$pgPort/$database',
    'LAB_SECRET_KEY_BASE': _hex(48),
    'LAB_TOKEN_SIGNING_SECRET': instance['jwtSecret']! as String,
    'LAB_WEB_ORIGIN': webUrl,
    'LAB_WEB_ORIGINS': [
      webUrl,
      ?Platform.environment['MOMENTS_SUITE_ORIGIN'],
    ].join(','),
    'LAB_PORT':
        '${Uri.parse(instance['apiUrl'] as String? ?? 'http://127.0.0.1:4000').port}',
    'MOMENTS_RECIPE_TOKEN': recipeToken(instance),
    'LAB_SERVER': operation == 'serve' ? 'true' : 'false',
    'MIX_ENV': operation == 'test' ? 'test' : 'dev',
    for (final key in pass)
      if (Platform.environment[key] case final value?) key: value,
  };
  Future<void> run(List<String> args) =>
      mix(server, args, environment: environment, hostNetwork: true);
  void createDatabase() {
    final container = instance['container']! as String;
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
  }

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
