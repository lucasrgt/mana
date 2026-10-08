import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';
import 'manifest.dart';

typedef Plugin = ({String source, String name, Map<String, Object?>? servers});
typedef ServerConfig = ({
  String command,
  List<String> args,
  Map<String, String> env,
});

void _inspectTree(Directory root) {
  for (final item in root.listSync(followLinks: false)) {
    final type = FileSystemEntity.typeSync(item.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.directory &&
            type != FileSystemEntityType.file)) {
      throw ManaFailure('Unsupported plugin entry: ${item.path}');
    }
    if (type == FileSystemEntityType.directory) {
      _inspectTree(Directory(item.path));
    }
  }
}

List<Plugin> pluginPlan(String root, List<String> paths) {
  final names = {'mana-project-skills'};
  return [
    for (final path in paths)
      () {
        final source = projectPath(root, path);
        if (!Directory(source).existsSync()) {
          throw ManaFailure('Invalid plugin directory: $path');
        }
        _inspectTree(Directory(source));
        final manifest =
            jsonDecode(
                  File(
                    p.join(source, '.claude-plugin/plugin.json'),
                  ).readAsStringSync(),
                )
                as Map;
        final name = manifest['name'];
        if (name is! String ||
            !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name) ||
            !names.add(name)) {
          throw ManaFailure('Invalid or duplicate plugin name: $name');
        }
        final toml = File(p.join(source, '.mcp.toml')),
            json = File(p.join(source, '.mcp.json'));
        if (toml.existsSync() && json.existsSync()) {
          throw ManaFailure(
            'Plugin declares both .mcp.toml and .mcp.json: $path',
          );
        }
        final servers = toml.existsSync()
            ? TomlDocument.parse(toml.readAsStringSync()).toMap()
            : null;
        servers?.values.forEach(validateServer);
        if (json.existsSync()) jsonDecode(json.readAsStringSync());
        return (source: source, name: name, servers: servers);
      }(),
  ];
}

ServerConfig serverConfig(Object? raw, Map<String, String> variables) {
  final server = (raw! as Map).cast<String, Object?>();
  final command = [
    for (final value in argv(server['command'], 'mcp.command'))
      expand(value, variables),
  ];
  final env = {
    for (final MapEntry(:key, :value) in environment(
      server['env'] ?? const {},
    ).entries)
      key: expand(value, variables),
  };
  return (command: command.first, args: command.skip(1).toList(), env: env);
}

Map<String, Object?> serverJson(ServerConfig server) => {
  'command': server.command,
  'args': server.args,
  'env': server.env,
};

void _copyTree(Directory from, Directory to) {
  if (to.existsSync()) {
    throw ManaFailure('Plugin destination exists: ${to.path}');
  }
  to.createSync(recursive: true);
  for (final item in from.listSync(followLinks: false)) {
    final target = p.join(to.path, p.basename(item.path));
    if (item is Directory) {
      _copyTree(item, Directory(target));
    } else if (item is File) {
      item.copySync(target);
    }
  }
}

List<String> copyPlugins(
  List<Plugin> plugins,
  Map<String, String> skills,
  String session,
  Map<String, String> variables,
) {
  final paths = <String>[];
  for (final plugin in plugins) {
    final destination = p.join(session, 'plugins', plugin.name);
    _copyTree(Directory(plugin.source), Directory(destination));
    if (plugin.servers case final servers?) {
      final json = {
        for (final MapEntry(:key, :value) in servers.entries)
          key: {'type': 'stdio', ...serverJson(serverConfig(value, variables))},
      };
      File(p.join(destination, '.mcp.json')).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(json)}\n',
      );
      File(p.join(destination, '.mcp.toml')).deleteSync();
    }
    paths.add(destination);
  }
  if (skills.isNotEmpty) {
    final destination = p.join(session, 'plugins/mana-project-skills');
    Directory(
      p.join(destination, '.claude-plugin'),
    ).createSync(recursive: true);
    Directory(p.join(destination, 'skills')).createSync();
    File(p.join(destination, '.claude-plugin/plugin.json')).writeAsStringSync(
      jsonEncode({'name': 'mana-project-skills', 'version': '0.1.0'}),
    );
    for (final MapEntry(key: name, value: source) in skills.entries) {
      Link(p.join(destination, 'skills', name)).createSync(source);
    }
    paths.add(destination);
  }
  return paths;
}
