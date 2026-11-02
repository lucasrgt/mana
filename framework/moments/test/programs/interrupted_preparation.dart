import 'dart:convert';
import 'dart:io';

import 'package:mana/runtime.dart' show uuidV4;
import 'package:moments/src/backend_recipes.dart';
import 'package:moments/src/preparation_retry.dart';
import 'package:path/path.dart' as p;

/// A backend whose databases are files under [directory], so what one
/// process prepared is there for the next: `shared.json` is the shared
/// database, `scopes/<id>.json` a data scope, `snapshots/<name>.json` a
/// captured one, `runs.json` how many times each recipe ran.
final class FileBackend {
  FileBackend(this.directory);
  final String directory;

  /// The recipe whose transition kills its process after a first write.
  String? killDuring;
  String digest = 'digest-1';

  File _file(String path) => File(p.join(directory, path));
  List<String> rows(String path) =>
      _file(path).existsSync() ? (jsonDecode(_file(path).readAsStringSync()) as List).cast() : <String>[];
  void _write(String path, List<String> rows) {
    _file(path).parent.createSync(recursive: true);
    _file(path).writeAsStringSync(jsonEncode(rows));
  }

  Map<String, int> runs() =>
      _file('runs.json').existsSync() ? (jsonDecode(_file('runs.json').readAsStringSync()) as Map).cast() : {};
  List<String> scope(String id) => rows('scopes/$id.json');
  List<String> get shared => rows('shared.json');
  bool snapshot(String name) => _file('snapshots/$name.json').existsSync();

  Map<String, Object?> _prepare(String recipe, bool isolated, List<String> from) {
    _file('runs.json')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(jsonEncode({...runs(), recipe: (runs()[recipe] ?? 0) + 1}));
    final id = uuidV4().substring(0, 12), target = isolated ? 'scopes/$id.json' : 'shared.json';
    final written = [...(isolated ? from : shared), recipe];
    if (killDuring == recipe) {
      _write(target, [...written, '$recipe (partial)']);
      Process.killPid(pid, ProcessSignal.sigkill);
      sleep(const Duration(seconds: 10));
    }
    _write(target, written);
    return {
      'launch': {
        'route': '/$recipe',
        'inputs': {'$recipe.id': id},
        if (isolated) 'dataScope': id,
      },
    };
  }

  /// The adapter of [recipe]: in a database of its own when [isolated];
  /// [describes] false for an adapter that cannot tell (an older plug).
  RecipeAdapter adapter(String recipe, {bool isolated = true, bool describes = true}) => RecipeAdapter(
    prepare: (_) async => _prepare(recipe, isolated, const []),
    prepareFrom: (_, parent, {snapshot}) async =>
        _prepare(recipe, isolated, snapshot == null ? const [] : rows('snapshots/$snapshot.json')),
    describe: describes
        ? (_, {snapshot}) async =>
              (isolated: isolated, digest: digest, snapshot: snapshot != null && this.snapshot(snapshot))
        : null,
    capture: (_, launch, snapshot) async => _write('snapshots/$snapshot.json', scope(launch['dataScope']! as String)),
    inspect: (instance, _) async => {
      'status': 'ready',
      'projection': {'rows': isolated ? scope((instance['launch']! as Map)['dataScope']! as String) : shared},
    },
  );

  Map<String, RecipeAdapter> adapters({bool isolated = true}) => {
    for (final recipe in ['shop', 'paid', 'refunded']) recipe: adapter(recipe, isolated: isolated),
  };
}

/// How `up` drives a preparation (sandbox.dart), with its instance in
/// `instance.json` under [directory].
BackendRecipes engine(String directory, FileBackend backend, {bool isolated = true}) {
  final file = File(p.join(directory, 'instance.json'));
  Map<String, Object?> read() => (jsonDecode(file.readAsStringSync()) as Map).cast();
  void write(Map<String, Object?> instance) => file.writeAsStringSync(jsonEncode(instance));
  return BackendRecipes(
    manifestFile: p.join(directory, 'moments/manifest.json'),
    recipes: backend.adapters(isolated: isolated),
    instance: read,
    assertAvailable: () async {},
    beforePrepare: (_) async {
      write(preparationAt(read(), 'services'));
      write(preparationAt(read(), 'recipe'));
    },
    onTransition: (moment, isolated) => write(preparationTransition(read(), moment, isolated)),
    commit: (launch, {base, preparedMoment}) async =>
        write({...read(), 'launch': launch, 'phase': 'ready', 'preparedMoment': ?preparedMoment}),
  );
}

/// `interrupted_preparation <directory> <moment> <recipe to die in> <isolated|shared>`
Future<void> main(List<String> args) async {
  final [directory, moment, killDuring, layer] = args;
  final backend = FileBackend(p.join(directory, 'db'))..killDuring = killDuring;
  await engine(directory, backend, isolated: layer == 'isolated').prepare(moment);
}
