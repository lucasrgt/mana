import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show mix;
import 'package:path/path.dart' as p;

import 'backend_recipes.dart';
import 'composition.dart' show Interruption;
import 'elixir_recipes.dart';
import 'errors.dart';
import 'json.dart';
import 'manifest.dart';
import 'services.dart';

/// An app's `moments/backend.json`: the declaration the runner needs to
/// start, sync and drive that app's Moments. Data, not code — commands are
/// argv lists, readiness is a URL and its expected JSON, defines are
/// templates over the sandbox instance.
final class Adapter {
  Adapter._(this.project, this.file, this._json);

  factory Adapter.load(String project) {
    final file = p.join(project, 'moments/backend.json');
    if (!File(file).existsSync()) throw MomentsError('Missing Moments adapter: $file');
    final json = (jsonDecode(File(file).readAsStringSync()) as Map).cast<String, Object?>();
    if (json['version'] != 1) throw const MomentsError('Unsupported moments/backend.json version');
    const allowed = [
      'version',
      'name',
      'initialMoment',
      'ports',
      'database',
      'databaseImage',
      'restartOnOpen',
      'sync',
      'services',
      'recipes',
      'inputs',
      'flutterDefines',
      'headless',
      'entrypoint',
      'device',
      'watch',
      'renew',
    ];
    for (final key in json.keys) {
      if (!allowed.contains(key)) throw MomentsError('Unknown moments/backend.json field: $key');
    }
    return Adapter._(p.normalize(p.absolute(project)), file, json);
  }

  final String project;
  final String file;
  final Map<String, Object?> _json;

  String get manifestFile => p.join(project, 'moments/manifest.json');
  String get name => _json['name']! as String;
  String get initialMoment => (_json['initialMoment'] ?? _json['name'])! as String;
  Map<String, Object?> get _ports => (_json['ports'] as Map?)?.cast() ?? const {};
  int get apiPort => _ports['api'] as int? ?? 5187;
  int get webPort => _ports['web'] as int? ?? 5186;
  int? get suitePort => _ports['suite'] as int?;
  int get bridgePort => _ports['bridge'] as int? ?? 18741;
  String get database => _json['database'] as String? ?? 'moments';
  String get databaseImage => _json['databaseImage'] as String? ?? 'postgres:16';
  bool get restartOnOpen => _json['restartOnOpen'] == true;
  String? get entrypoint => _json['entrypoint'] as String?;
  ({String file, String function})? get headless {
    final value = _json['headless'] as Map?;
    if (value == null) return null;
    return (file: value['file']! as String, function: value['function']! as String);
  }

  String _path(String relative) => p.normalize(p.join(project, relative));

  /// `${project}`, `${root}` (the checkout holding `framework/`) and
  /// `${instance.<key>}`.
  String expand(String value, [Map<String, Object?>? instance]) =>
      value.replaceAllMapped(RegExp(r'\$\{([A-Za-z.]+)\}'), (match) {
        final key = match[1]!;
        if (key == 'project') return project;
        if (key == 'root') return root;
        if (key.startsWith('instance.') && instance != null) {
          final found = instance[key.substring(9)];
          if (found is String) return found;
        }
        throw MomentsError('Unknown template in moments/backend.json: \${$key}');
      });

  String get root {
    var directory = project;
    while (!Directory(p.join(directory, 'framework/moments')).existsSync()) {
      final parent = p.dirname(directory);
      if (parent == directory) throw const MomentsError('Cannot find the framework checkout above this app');
      directory = parent;
    }
    return directory;
  }

  /// Moments whose recipe can be renewed in place; null when the adapter
  /// declares no `renew` command.
  List<String>? get renewable {
    final renew = _json['renew'] as Map?;
    if (renew == null) return null;
    return ((renew['moments'] as List?) ?? const []).cast<String>();
  }

  /// Runs the `renew` command with the instance on stdin and returns the new
  /// launch it prints. Interrupting kills the command; its output is discarded.
  Future<Map<String, Object?>> renew(Map<String, Object?> instance, Interruption signal) async {
    final renew = (_json['renew'] as Map?)?.cast<String, Object?>();
    final command = (renew?['command'] as List?)?.cast<String>().map(expand).toList();
    if (command == null || command.isEmpty) throw const MomentsError('This launcher cannot renew its recipe');
    final child = await Process.start(command.first, command.skip(1).toList(), workingDirectory: project);
    void kill() => child.kill(ProcessSignal.sigterm);
    signal.onAbort(kill);
    try {
      child.stdin.add(
        utf8.encode(
          jsonEncode({
            'apiUrl': instance['apiUrl'],
            'container': instance['container'],
            'password': instance['password'],
            'launch': instance['launch'],
          }),
        ),
      );
      await child.stdin.close();
      final output = child.stdout.transform(utf8.decoder).join();
      unawaited(child.stderr.drain<void>());
      final code = await child.exitCode;
      if (signal.aborted) throw const MomentsError('Renewal interrupted');
      if (code != 0) throw const MomentsError('Renewal recipe failed; the previous launch is kept');
      final value = jsonDecode(await output);
      if (value is! Map) throw const MomentsError('Renewal recipe returned no launch');
      return value.cast();
    } finally {
      signal.off(kill);
    }
  }

  Future<void> sync() async {
    final sync = (_json['sync'] as Map?)?.cast<String, Object?>();
    if (sync == null) throw const MomentsError('moments/backend.json declares no sync');
    final args = [for (final arg in ((sync['args'] as List?) ?? const []).cast<String>()) expand(arg)];
    if (sync['command'] case final List command) {
      final argv = [for (final part in command.cast<String>()) expand(part), ...args];
      final child = await Process.start(
        argv.first,
        argv.skip(1).toList(),
        workingDirectory: project,
        mode: ProcessStartMode.inheritStdio,
      );
      if (await child.exitCode != 0) throw const MomentsError('moments sync failed');
      return;
    }
    await mix(_path(sync['mix']! as String), args);
  }

  List<ServiceDefinition> services() => [
    for (final raw in (_json['services'] as List? ?? const []).cast<Map>())
      () {
        final s = raw.cast<String, Object?>();
        final ready = (s['ready']! as Map).cast<String, Object?>();
        final url = ready['url']! as String;
        final expected = (ready['json'] as Map?)?.cast<String, Object?>();
        List<String>? command(String key) => (s[key] as List?)?.cast<String>().map(expand).toList();
        return ServiceDefinition(
          name: s['name']! as String,
          cwd: _path(s['cwd'] as String? ?? '.'),
          port: s['port']! as int,
          prepare: command('prepare'),
          compile: command('compile'),
          serve: command('serve')!,
          prepareIdempotent: s['prepareIdempotent'] == true,
          watch: (s['watch'] as List? ?? const []).cast<String>(),
          environment: {
            for (final MapEntry(:key, :value)
                in ((s['environment'] as Map?) ?? const {}).cast<String, String>().entries)
              key: expand(value),
          },
          timeout: s['timeout'] is int ? Duration(milliseconds: s['timeout']! as int) : null,
          commandTimeout: s['commandTimeout'] is int ? Duration(milliseconds: s['commandTimeout']! as int) : null,
          ready: () => _probe(url, expected),
        );
      }(),
  ];

  static Future<bool> _probe(String url, Map<String, Object?>? expected) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final response = await (await client.getUrl(Uri.parse(url))).close().timeout(const Duration(seconds: 1));
      final body = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 1));
      if (response.statusCode < 200 || response.statusCode >= 300) return false;
      if (expected == null) return true;
      final value = jsonDecode(body);
      return value is Map && expected.entries.every((e) => jsonEqual(value[e.key], e.value));
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// Recipes named by the manifest, implemented by the backend itself
  /// (`recipes: "elixir"`, served at `/__moments`).
  Map<String, RecipeAdapter> recipes() {
    final kind = _json['recipes'] ?? 'elixir';
    if (kind != 'elixir') throw MomentsError('Unsupported recipe source: $kind');
    final moments = (readManifest(manifestFile)['moments']! as Map).values.cast<Map>();
    return elixirRecipes({
      for (final scene in moments)
        if ((scene['backend'] as Map?)?['recipe'] case final String recipe) recipe,
    });
  }

  String Function(Map<String, Object?> instance, String reference)? get resolveInput =>
      (_json['inputs'] ?? 'recipe') == 'recipe' ? recipeInput : null;

  Map<String, String> flutterDefines(Map<String, Object?> instance) => {
    for (final MapEntry(:key, :value) in ((_json['flutterDefines'] as Map?) ?? const {}).cast<String, String>().entries)
      key: expand(value, instance),
  };

  List<Map<String, Object?>> catalog() => manifestCatalog(manifestFile);
}
