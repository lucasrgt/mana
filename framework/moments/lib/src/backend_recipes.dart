import 'errors.dart';
import 'json.dart';
import 'manifest.dart';
import 'protocol.dart';

typedef Instance = Map<String, Object?>;

final class RecipeAdapter {
  const RecipeAdapter({required this.prepare, required this.inspect});
  final Future<Map<String, Object?>?> Function(Instance instance) prepare;
  final Future<Map<String, Object?>> Function(Instance instance, Map<String, Object?> context) inspect;
}

final class BaseAdapter {
  const BaseAdapter({required this.prepare});
  final Future<Map<String, Object?>?> Function(Instance instance) prepare;
}

Map<String, Object?> _preparedIdentity(String name, String recipe, String? base) => {
  'version': 1,
  'moment': name,
  'recipe': recipe,
  'base': base,
};

bool preparedRecipeMatches(Instance? instance, String name, Map<String, Object?>? backend) =>
    backend != null &&
    instance?['phase'] == 'ready' &&
    instance?['launch'] != null &&
    instance?['preparation'] == null &&
    deepEqual(
      instance?['preparedMoment'],
      _preparedIdentity(name, backend['recipe']! as String, backend['base'] as String?),
    );

typedef Commit =
    Future<void> Function(Map<String, Object?> launch, {String? base, Map<String, Object?>? preparedMoment});

/// The declaration selects registered adapters, never a file, shell command or
/// credential. One shared base per instance; specific recipes run on each open.
final class BackendRecipes {
  BackendRecipes({
    required this.manifestFile,
    this.recipes = const {},
    this.bases = const {},
    required this.instance,
    required this.assertAvailable,
    this.commit,
    this.startBase,
    void Function() Function()? acquire,
    Future<void> Function(String name)? beforePrepare,
  }) : _acquire = acquire ?? (() => () {}),
       _beforePrepare = beforePrepare ?? ((_) async {});

  final String manifestFile;
  final Map<String, RecipeAdapter> recipes;
  final Map<String, BaseAdapter> bases;
  final Instance Function() instance;
  final Future<void> Function() assertAvailable;
  final Commit? commit;
  final Future<void> Function(String base)? startBase;
  final void Function() Function() _acquire;
  final Future<void> Function(String name) _beforePrepare;
  var _preparing = false;

  static bool _identifier(Object? value) => value is String && RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(value);

  Map<String, Object?> _scene(String name) {
    final scene = (readManifest(manifestFile)['moments']! as Map)[name];
    if (scene == null) throw const MomentsError('Unknown Moment');
    return (scene as Map).cast();
  }

  ({String name, RecipeAdapter adapter, ({String name, BaseAdapter adapter})? base})? _resolve(String name) {
    final scene = _scene(name);
    if (!scene.containsKey('backend')) return null;
    final value = scene['backend'];
    if (value is! Map ||
        value.keys.any((key) => !const ['recipe', 'base'].contains(key)) ||
        !_identifier(value['recipe']) ||
        (value.containsKey('base') && !_identifier(value['base']))) {
      throw const MomentsError('Invalid backend recipe declaration');
    }
    final recipe = value['recipe'] as String;
    final adapter = recipes[recipe];
    if (adapter == null) throw MomentsError('Backend recipe is not registered: $recipe');
    ({String name, BaseAdapter adapter})? base;
    if (value['base'] case final String baseName) {
      final baseAdapter = bases[baseName];
      if (baseAdapter == null) throw MomentsError('Backend base is not registered: $baseName');
      final current = instance()['baseRecipe'];
      if (current != null && current != baseName) {
        throw const MomentsError('Instance belongs to a different backend base');
      }
      base = (name: baseName, adapter: baseAdapter);
    }
    return (name: recipe, adapter: adapter, base: base);
  }

  Future<void> _persist(Map<String, Object?>? result, {String? base, Map<String, Object?>? preparedMoment}) async {
    if (result == null || result.length != 1 || result['launch'] is! Map) {
      throw const MomentsError('Backend preparation must return undefined or {launch}');
    }
    final save = commit;
    if (save == null) throw const MomentsError('Backend launch persistence is not configured');
    await assertAvailable();
    await save((result['launch']! as Map).cast(), base: base, preparedMoment: preparedMoment);
  }

  Future<void> _ensureBase(({String name, BaseAdapter adapter})? base) async {
    if (base == null) return;
    final current = instance();
    if (current['phase'] == 'seeding') {
      throw const MomentsError('Previous base preparation was interrupted; reset this local instance explicitly');
    }
    if (current['baseRecipe'] == base.name && current['launch'] != null) return;
    // Existing instances are adopted through the app adapter, never guessed
    // from a route or silently reseeded. New bases checkpoint before any write.
    if (current['launch'] == null) {
      final start = startBase;
      if (start == null) throw const MomentsError('Backend base checkpoint is not configured');
      await start(base.name);
    }
    await _persist(await base.adapter.prepare(instance()), base: base.name);
  }

  bool declared(String? name) => name != null && _resolve(name) != null;

  Future<void> prepare(String name) async {
    assertMaterializable(_scene(name));
    final recipe = _resolve(name);
    if (recipe == null) return;
    final identity = _preparedIdentity(name, recipe.name, recipe.base?.name);
    if (_preparing) throw const MomentsError('Backend preparation is already running');
    _preparing = true;
    void Function()? release;
    try {
      await assertAvailable();
      release = _acquire();
      await _ensureBase(recipe.base);
      await _beforePrepare(name);
      final result = await recipe.adapter.prepare(instance());
      await assertAvailable();
      final latest = _resolve(name)!;
      if (!deepEqual(identity, _preparedIdentity(name, latest.name, latest.base?.name))) {
        throw const MomentsError('Backend declaration changed during preparation');
      }
      // Persist launch and its identity together. Resuming cannot guess which
      // recipe produced private inputs from the screen route alone.
      if (result != null) {
        await _persist(result, preparedMoment: identity);
      } else if (instance()['launch'] != null && commit != null) {
        await _persist({'launch': instance()['launch']}, preparedMoment: identity);
      }
    } finally {
      release?.call();
      _preparing = false;
    }
  }

  Future<Map<String, Object?>> inspect(String name, {Map<String, Object?> context = const {}}) async {
    final recipe = _resolve(name);
    if (recipe == null) throw const MomentsError('Moment has no declared backend recipe');
    if (_preparing) throw const MomentsError('Backend preparation is in progress');
    await assertAvailable();
    final current = instance();
    if (recipe.base != null &&
        (current['baseRecipe'] != recipe.base!.name || current['phase'] != 'ready' || current['launch'] == null)) {
      throw const MomentsError('Backend base has not been prepared');
    }
    // Query inputs may follow the observed screen (page/filter). An adapter
    // must still read backend data independently; UI data is not evidence.
    return {
      ...await recipe.adapter.inspect(current, jsonCopy(context)),
      'recipe': recipe.name,
      if (recipe.base != null) 'base': recipe.base!.name,
    };
  }
}
