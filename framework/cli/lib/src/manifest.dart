import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';

typedef Config = Map<String, Object?>;

String projectPath(String root, Object? value, {bool allowRoot = false}) {
  if (value is! String || value.isEmpty || p.isAbsolute(value)) {
    throw const ManaFailure('Project paths must be relative');
  }
  final target = p.normalize(p.join(root, value));
  final rel = p.relative(target, from: root);
  if ((rel == '.' && !allowRoot) ||
      rel == '..' ||
      rel.startsWith('../') ||
      p.isAbsolute(rel)) {
    throw ManaFailure('Path escapes project: $value');
  }
  var current = root;
  for (final part
      in rel.split('/').where((part) => part.isNotEmpty && part != '.')) {
    current = p.join(current, part);
    if (FileSystemEntity.isLinkSync(current)) {
      throw ManaFailure('Symlink not allowed: $current');
    }
  }
  return target;
}

Config readManifest(String root, {bool legacy = false}) {
  final file = projectPath(root, 'mana.toml');
  if (File(file).existsSync()) {
    if (File(p.join(root, 'mana.json')).existsSync()) {
      throw const ManaFailure(
        'Both mana.toml and mana.json exist; choose one manifest',
      );
    }
    try {
      return TomlDocument.parse(File(file).readAsStringSync()).toMap();
    } on TomlException catch (error) {
      throw ManaFailure('Invalid mana.toml: $error');
    }
  }
  throw ManaFailure('Missing mana.toml: $root');
}

String findProject([String? start]) {
  var root = Directory(
    start ?? Directory.current.path,
  ).resolveSymbolicLinksSync();
  while (!File(p.join(root, 'mana.toml')).existsSync()) {
    if (p.dirname(root) == root) {
      throw const ManaFailure('No mana.toml found; pass --project');
    }
    root = p.dirname(root);
  }
  return root;
}

List<String> argv(Object? value, String label) {
  if (value is! List ||
      value.isEmpty ||
      value.any((v) => v is! String || v.isEmpty || v.contains('\x00'))) {
    throw ManaFailure('Invalid $label: expected nonempty argv');
  }
  return value.cast<String>();
}

Map<String, Object?> _table(Object? value, List<String> allowed, String label) {
  if (value is! Map) throw ManaFailure('Invalid $label');
  for (final key in value.keys) {
    if (!allowed.contains(key)) throw ManaFailure('Unknown $label.$key');
  }
  return value.cast<String, Object?>();
}

void _strings(Object? value, String label) {
  if (value is! List ||
      value.any((v) => v is! String || v.isEmpty) ||
      value.toSet().length != value.length) {
    throw ManaFailure('Invalid $label');
  }
}

Map<String, Object?> table(Config config, String key) =>
    (config[key] as Map?)?.cast<String, Object?>() ?? const {};

List<Object?> list(Object? value) => value as List? ?? const [];

List<String> frontends(Map<String, Object?> product) =>
    switch (product['frontend']) {
      final String one => [one],
      final List many => many.cast<String>(),
      _ => const [],
    };

Config validate(Config config) {
  _table(config, const [
    'version',
    'module',
    'otpApp',
    'server',
    'app',
    'apiPackage',
    'fixtureActorId',
    'database',
    'base',
    'baseDomains',
    'products',
    'setup',
    'agents',
    'mcp',
  ], 'manifest');
  if (config['version'] != 1) {
    throw const ManaFailure('Unsupported mana.toml version');
  }
  for (final MapEntry(key: name, value: product) in table(
    config,
    'products',
  ).entries) {
    if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name)) {
      throw ManaFailure('Invalid product name: $name');
    }
    final fields = _table(product, const [
      'backend',
      'frontend',
    ], 'products.$name');
    final backend = fields['backend'];
    final front = fields['frontend'] is String
        ? [fields['frontend']]
        : fields['frontend'] ?? const [];
    if ((backend != null && (backend is! String || backend.isEmpty)) ||
        (backend == null && (front as List).isEmpty)) {
      throw ManaFailure(
        'Invalid products.$name: declare a backend, a frontend or both',
      );
    }
    _strings(front, 'products.$name.frontend');
  }
  final setup = _table(config['setup'] ?? const {}, const [
    'tasks',
    'artifacts',
  ], 'setup');
  for (final key in ['tasks', 'artifacts']) {
    if (setup[key] != null && setup[key] is! List) {
      throw ManaFailure('Invalid setup.$key');
    }
  }
  for (final task in list(setup['tasks'])) {
    final fields = _table(task, const [
      'name',
      'cwd',
      'command',
      'timeout_seconds',
    ], 'task');
    argv(fields['command'], 'task.command');
    final name = fields['name'];
    if (name is! String ||
        name.isEmpty ||
        (fields['cwd'] != null && fields['cwd'] is! String)) {
      throw const ManaFailure('Invalid task name/cwd');
    }
    final timeout = fields['timeout_seconds'] ?? 600;
    if (timeout is! int || timeout < 1) {
      throw const ManaFailure('Invalid task timeout');
    }
  }
  final destinations = <String>{};
  for (final artifact in list(setup['artifacts'])) {
    final fields = _table(artifact, const [
      'source',
      'path',
      'sha256',
    ], 'artifact');
    final path = fields['path'], sha = fields['sha256'];
    if (fields['source'] is! String ||
        path is! String ||
        !path.startsWith('.mana/bin/') ||
        sha is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw const ManaFailure('Invalid artifact source/path/sha256');
    }
    if (!destinations.add(path)) {
      throw const ManaFailure('Duplicate artifact destination');
    }
  }
  final mcp = table(config, 'mcp');
  for (final MapEntry(key: name, value: agent) in _table(
    config['agents'] ?? const {},
    const ['claude', 'codex'],
    'agents',
  ).entries) {
    final fields = _table(
      agent,
      name == 'claude'
          ? const [
              'command',
              'mods',
              'skills',
              'mcp',
              'tools',
              'disallowed_tools',
              'env',
            ]
          : const ['command', 'skills', 'mcp', 'env'],
      'agents.$name',
    );
    argv(fields['command'] ?? [name], 'agent.command');
    for (final key in ['mods', 'skills', 'mcp', 'tools', 'disallowed_tools']) {
      _strings(fields[key] ?? const [], key);
    }
    final env = environment(fields['env'] ?? const {});
    if (env.containsKey('MANA_PROJECT') || env.containsKey('MANA_SESSION')) {
      throw const ManaFailure(
        'Agent environment cannot override Mana project/session paths',
      );
    }
    for (final server in list(fields['mcp'])) {
      if (mcp[server] == null) throw ManaFailure('Unknown MCP server: $server');
    }
  }
  for (final MapEntry(key: name, value: server) in mcp.entries) {
    if (!RegExp(r'^[a-z][a-z0-9_-]*$').hasMatch(name)) {
      throw ManaFailure('Invalid MCP name: $name');
    }
    validateServer(server);
  }
  return config;
}

typedef Product = ({String name, String? backend, List<String> frontend});

List<Product> productPaths(String root, Config config) => [
  for (final MapEntry(key: name, value: raw) in table(
    config,
    'products',
  ).entries)
    () {
      final product = (raw! as Map).cast<String, Object?>();
      final backend = product['backend'] as String?;
      final frontend = frontends(product);
      for (final path in [?backend, ...frontend]) {
        if (!Directory(projectPath(root, path)).existsSync() ||
            FileSystemEntity.isLinkSync(projectPath(root, path))) {
          throw ManaFailure('Missing product directory: $name -> $path');
        }
      }
      return (name: name, backend: backend, frontend: frontend);
    }(),
];

Map<String, String> environment(Object? value) {
  if (value is! Map ||
      value.entries.any(
        (e) =>
            e.key is! String ||
            !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(e.key as String) ||
            e.value is! String ||
            (e.value as String).contains('\x00'),
      )) {
    throw const ManaFailure('Invalid environment map');
  }
  return value.cast<String, String>();
}

void validateServer(Object? server) {
  final fields = _table(server, const ['command', 'env'], 'mcp server');
  argv(fields['command'], 'mcp.command');
  environment(fields['env'] ?? const {});
}

String expand(String value, Map<String, String> variables) =>
    value.replaceAllMapped(RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}'), (match) {
      final found = variables[match[1]];
      if (found == null || found.isEmpty) {
        throw ManaFailure('Missing environment variable: ${match[1]}');
      }
      return found;
    });

List<String> selected(Config config, String? option) {
  final agents = table(config, 'agents');
  final names = option != null ? option.split(',') : agents.keys.toList();
  if (names.isEmpty ||
      names.toSet().length != names.length ||
      names.any((n) => agents[n] == null)) {
    throw const ManaFailure('Select configured agents: claude,codex');
  }
  return names;
}
