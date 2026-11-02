import 'package:path/path.dart' as p;

import 'checkpoints.dart';
import 'errors.dart';
import 'json.dart';
import 'manifest.dart';

typedef Instance = Map<String, Object?>;

final class RecipeAdapter {
  const RecipeAdapter({required this.prepare, required this.inspect, this.prepareFrom, this.describe, this.capture});
  final Future<Map<String, Object?>?> Function(Instance instance) prepare;
  final Future<Map<String, Object?>> Function(Instance instance, Map<String, Object?> context) inspect;

  /// [prepare] for a child: [parent] is its parent's launch and, when the
  /// parent was captured, [snapshot] is the snapshot to run in a clone of.
  /// Without it a child's recipe runs as [prepare], on the data its parent
  /// left in the shared database.
  final Future<Map<String, Object?>?> Function(Instance instance, Map<String, Object?> parent, {String? snapshot})?
  prepareFrom;
  final Future<Description?> Function(Instance instance, {String? snapshot})? describe;
  final Future<void> Function(Instance instance, Map<String, Object?> launch, String snapshot)? capture;
}

final class BaseAdapter {
  const BaseAdapter({required this.prepare});
  final Future<Map<String, Object?>?> Function(Instance instance) prepare;
}

/// What a prepared launch is the result of: the Moment, its recipe and base
/// and, for a child, its parent's identity. Null when nothing in the chain
/// declares a recipe.
Map<String, Object?>? preparedIdentity(Map<Object?, Object?> moments, String name) {
  final scene = moments[name] as Map?;
  if (scene == null) return null;
  final backend = scene['backend'] as Map?;
  final parent = scene['from'] is String ? preparedIdentity(moments, scene['from']! as String) : null;
  if (backend == null && parent == null) return null;
  return {'version': 1, 'moment': name, 'recipe': backend?['recipe'], 'base': backend?['base'], 'from': ?parent};
}

/// Whether [instance] holds a completed preparation of root [name] with
/// [backend]'s recipe and base.
bool preparedRecipeMatches(Instance? instance, String name, Map<String, Object?>? backend) =>
    backend != null &&
    preparedMomentMatches(
      instance,
      preparedIdentity({
        name: {'backend': backend},
      }, name),
    );

bool preparedMomentMatches(Instance? instance, Map<String, Object?>? identity) =>
    identity != null &&
    instance?['phase'] == 'ready' &&
    instance?['launch'] != null &&
    instance?['preparation'] == null &&
    deepEqual(instance?['preparedMoment'], identity);

typedef Commit =
    Future<void> Function(Map<String, Object?> launch, {String? base, Map<String, Object?>? preparedMoment});

/// The declaration selects registered adapters, never a file, shell command or
/// credential. One shared base per instance; specific recipes run on each open.
/// A child is prepared on its parent's checkpoint ([composeChain]), kept in
/// [checkpoints] (by default `.backend/checkpoints.json` beside the manifest).
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
    this.onTransition,
    CheckpointStore? checkpoints,
  }) : _acquire = acquire ?? (() => () {}),
       _beforePrepare = beforePrepare ?? ((_) async {}),
       checkpoints = checkpoints ?? CheckpointStore(p.join(p.dirname(manifestFile), '.backend', 'checkpoints.json'));

  final String manifestFile;
  final Map<String, RecipeAdapter> recipes;
  final Map<String, BaseAdapter> bases;
  final Instance Function() instance;
  final Future<void> Function() assertAvailable;
  final Commit? commit;
  final Future<void> Function(String base)? startBase;
  final void Function() Function() _acquire;
  final Future<void> Function(String name) _beforePrepare;
  final void Function(String moment, bool isolated)? onTransition;
  final CheckpointStore checkpoints;
  var _preparing = false;

  /// How the last preparation's chain came to be ([Composed.path]).
  List<Map<String, Object?>> lastPath = const [];

  static bool _identifier(Object? value) => value is String && RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(value);

  Map<String, Object?> _scene(String name) {
    final scene = (readManifest(manifestFile)['moments']! as Map)[name];
    if (scene == null) throw const MomentsError('Unknown Moment');
    return (scene as Map).cast();
  }

  /// [name] and its declared ancestors, root first.
  List<String> _ancestry(String name) => [
    for (String? current = name; current != null; current = _scene(current)['from'] as String?) current,
  ].reversed.toList();

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

  /// Whether [name] or one of its ancestors declares a recipe.
  bool declared(String? name) => name != null && _ancestry(name).any((moment) => _resolve(moment) != null);

  Map<String, Object?>? identity(String name) => preparedIdentity(readManifest(manifestFile)['moments']! as Map, name);

  static Map<String, Object?>? _launchOf(Map<String, Object?>? result) {
    if (result == null) return null;
    if (result.length != 1 || result['launch'] is! Map) {
      throw const MomentsError('Backend preparation must return undefined or {launch}');
    }
    return (result['launch']! as Map).cast();
  }

  Transition _transition(RecipeAdapter adapter) {
    final describe = adapter.describe, capture = adapter.capture, prepareFrom = adapter.prepareFrom;
    return Transition(
      prepare: ({parent, snapshot}) async {
        if (parent == null) return _launchOf(await adapter.prepare(instance()));
        if (prepareFrom != null) return _launchOf(await prepareFrom(instance(), parent, snapshot: snapshot));
        if (snapshot != null) throw const MomentsError('This recipe adapter cannot prepare from a snapshot');
        return _launchOf(await adapter.prepare(instance()));
      },
      describe: describe == null ? null : ({snapshot}) => describe(instance(), snapshot: snapshot),
      capture: capture == null ? null : (launch, snapshot) => capture(instance(), launch, snapshot),
    );
  }

  Future<void> prepare(String name) async {
    final moments = readManifest(manifestFile)['moments']! as Map;
    final chain = [for (final moment in _ancestry(name)) (moment: moment, recipe: _resolve(moment))];
    if (chain.every((link) => link.recipe == null)) return;
    final bases = {for (final link in chain) ?link.recipe?.base?.name};
    if (bases.length > 1) throw const MomentsError('A Moment and its ancestors declare different backend bases');
    final base = chain.map((link) => link.recipe?.base).nonNulls.firstOrNull;
    final identity = preparedIdentity(moments, name)!;
    if (_preparing) throw const MomentsError('Backend preparation is already running');
    _preparing = true;
    void Function()? release;
    try {
      await assertAvailable();
      release = _acquire();
      await _ensureBase(base);
      await _beforePrepare(name);
      final composed = await composeChain(
        [
          for (final link in chain)
            (
              moment: link.moment,
              identity: preparedIdentity(moments, link.moment) ?? const {},
              transition: link.recipe == null ? null : _transition(link.recipe!.adapter),
              parent: moments.values.any((scene) => (scene as Map)['from'] == link.moment),
            ),
        ],
        checkpoints,
        onTransition: onTransition,
      );
      lastPath = composed.path;
      await assertAvailable();
      if (!deepEqual(identity, this.identity(name))) {
        throw const MomentsError('Backend declaration changed during preparation');
      }
      // Persist launch and its identity together. Resuming cannot guess which
      // recipe produced private inputs from the screen route alone.
      if (composed.launch != null) {
        await _persist({'launch': composed.launch}, preparedMoment: identity);
      } else if (instance()['launch'] != null && commit != null) {
        await _persist({'launch': instance()['launch']}, preparedMoment: identity);
      }
    } finally {
      release?.call();
      _preparing = false;
    }
  }

  /// Observes through [name]'s recipe, or the nearest ancestor's when it
  /// declares none (its data is that ancestor's).
  Future<Map<String, Object?>> inspect(String name, {Map<String, Object?> context = const {}}) async {
    final recipe = _ancestry(name).reversed.map(_resolve).nonNulls.firstOrNull;
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
