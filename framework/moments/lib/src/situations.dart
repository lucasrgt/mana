import 'dart:convert';
import 'dart:io';

import 'package:mana/runtime.dart' show savePrivateState;
import 'package:path/path.dart' as p;

import 'backend_recipes.dart' show preparedIdentity;
import 'canonical.dart';
import 'checkpoints.dart';
import 'errors.dart';
import 'explorations.dart';
import 'manifest.dart';

/// One call to the app's recipes plug: `recipe` (or `_explorations`),
/// `operation` and its JSON body.
typedef RecipeCall = Future<Map<String, Object?>> Function(String recipe, String operation, Map<String, Object?> body);

/// The recipe path of a saved exploration's situations.
const explorations = '_explorations';

final _uuid = RegExp(r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
final _time = RegExp(r'^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?$');
final _secret = RegExp('password|token|secret|credential|jwt|cookie', caseSensitive: false);
final situationId = RegExp(r'^[a-z][a-z0-9-]*@[1-9][0-9]{0,5}$');
final _name = RegExp(r'^[a-z][a-z0-9-]*$');

/// What `diff` ignores, declared with every projection (the protocol's
/// "the normalization is declared").
const normalization = {
  'identifiers': 'UUIDs, anywhere in a value, become <id:N> in order of first appearance',
  'timestamps': 'ISO-8601 date-times become <time>',
  'secrets': 'values under keys naming a password, token, secret, credential, JWT or cookie become <secret>',
  'order': 'kept: table counts are by name and history is in the order it happened',
};

/// [value] without what differs between two evaluations of the same
/// situation ([normalization]); [ids] numbers identifiers across one
/// situation's layers.
Object? normalize(Object? value, [Map<String, String>? ids]) {
  ids ??= {};
  final seen = ids;
  return switch (value) {
    final Map map => {
      for (final key in map.keys.cast<String>().toList()..sort())
        key: _secret.hasMatch(key) && map[key] != null ? '<secret>' : normalize(map[key], seen),
    },
    final List items => [for (final item in items) normalize(item, seen)],
    final String text when _time.hasMatch(text) => '<time>',
    final String text => text.replaceAllMapped(
      _uuid,
      (match) => seen.putIfAbsent(match[0]!.toLowerCase(), () => '<id:${seen.length + 1}>'),
    ),
    _ => value,
  };
}

Map<String, Object?> _flatten(Object? value, [String path = '']) => switch (value) {
  final Map map when map.isNotEmpty => {
    for (final MapEntry(:key, value: inner) in map.entries) ..._flatten(inner, path.isEmpty ? '$key' : '$path.$key'),
  },
  _ => {path: value},
};

Map<String, int> _counted(List<Object?> entries) {
  final counts = <String, int>{};
  for (final entry in entries) {
    counts.update(jsonEncode(canonical(entry)), (n) => n + 1, ifAbsent: () => 1);
  }
  return counts;
}

List<Object?> _only(Map<String, int> mine, Map<String, int> theirs) => [
  for (final MapEntry(:key, value: n) in mine.entries)
    for (var i = 0; i < n - (theirs[key] ?? 0); i++) jsonDecode(key),
];

/// The difference between two normalized projections, per layer: tables
/// whose row counts differ, history entries one has and the other not, and
/// observed fields that differ.
Map<String, Object?> diffProjections(Map<String, Object?> a, Map<String, Object?> b) {
  final dataA = (a['data'] as Map?) ?? const {}, dataB = (b['data'] as Map?) ?? const {};
  final tablesA = ((dataA['tables'] as Map?) ?? const {}).cast<String, Object?>();
  final tablesB = ((dataB['tables'] as Map?) ?? const {}).cast<String, Object?>();
  final tables = {
    for (final table in {...tablesA.keys, ...tablesB.keys}.toList()..sort())
      if (tablesA[table] != tablesB[table]) table: [tablesA[table] ?? 0, tablesB[table] ?? 0],
  };
  final historyA = _counted((dataA['history'] as List?) ?? const []);
  final historyB = _counted((dataB['history'] as List?) ?? const []);
  final onlyA = _only(historyA, historyB), onlyB = _only(historyB, historyA);
  final observedA = _flatten(a['observe']), observedB = _flatten(b['observe']);
  final observe = {
    for (final path in {...observedA.keys, ...observedB.keys}.toList()..sort())
      if (jsonEncode(canonical(observedA[path])) != jsonEncode(canonical(observedB[path])))
        path: [observedA[path], observedB[path]],
  };
  return {
    'data': {
      'tables': tables,
      'history': {'onlyA': onlyA, 'onlyB': onlyB},
    },
    'observe': observe,
    'empty': tables.isEmpty && onlyA.isEmpty && onlyB.isEmpty && observe.isEmpty,
  };
}

/// What a saved exploration's map entry says to someone without the runner.
String describeMove(Map<String, Object?> move) {
  String ref(Object? value) => value is List && value.length == 2 ? '${value[0]} #${value[1]}' : '$value';
  return switch (move['kind']) {
    'verb' => '${move['actor']} performs ${move['verb']} on ${ref(move['ref'])}',
    'start' => '${move['actor']} starts ${move['verb']} on ${move['resource']}',
    'probe' => '${move['actor']} tries ${move['verb']} on ${ref(move['ref'])}, which is not offered',
    'clock' => 'the clock moves ${(move['by'] as List?)?.join(' ')}',
    _ => 'an unknown move (${move['kind']})',
  };
}

/// The protocol's instances at the data layer: a Moment prepared in a
/// database of its own (`data_scope: true`, `Mana.Snapshot`), forks of it and
/// saved explorations, each kept with the normalized projections it had when
/// it was made and the code it was made under. Launches stay in the private
/// `situations.json`; commands name situations by id (`<moment>@<n>`).
final class Situations {
  Situations({
    required this.project,
    required this.call,
    required this.backendVersion,
    this.context = const {},
    this.sync = _noSync,
  });

  final String project;
  final RecipeCall call;

  /// Exports the Ash declaration again (`moments sync`), so a trace `save`
  /// wrote becomes a Moment of the manifest.
  final Future<void> Function() sync;

  static Future<void> _noSync() => throw const MomentsError('This project has no Moments compiler');

  /// What a recipe's `prepare` receives as `context` (the API and web URLs).
  final Map<String, Object?> context;

  /// The applied backend sources, so a comparison knows whether two
  /// situations were made under the same code.
  final String Function() backendVersion;

  String get _file => p.join(project, 'moments/.backend/situations.json');
  String get mapFile => p.join(project, 'moments/explorations.md');
  String get _manifestFile => p.join(project, 'moments/manifest.json');

  static const _kept = 64;

  Map<String, Map<String, Object?>> _read() {
    if (!File(_file).existsSync()) return {};
    final value = jsonDecode(File(_file).readAsStringSync());
    if (value is! Map || value['version'] != 1 || value['situations'] is! Map) {
      throw const MomentsError('Unreadable situations.json; inspect or remove it');
    }
    return {
      for (final MapEntry(:key, :value) in (value['situations'] as Map).entries)
        key as String: (value as Map).cast<String, Object?>(),
    };
  }

  void _write(Map<String, Map<String, Object?>> situations) {
    final ids = situations.keys.toList()
      ..sort((a, b) => '${situations[a]!['createdAt']}'.compareTo('${situations[b]!['createdAt']}'));
    for (final id in ids.take(ids.length > _kept ? ids.length - _kept : 0)) {
      situations.remove(id);
    }
    Directory(p.dirname(_file)).createSync(recursive: true);
    savePrivateState(_file, {'version': 1, 'situations': situations});
  }

  Map<String, Object?> _scene(String moment) {
    final scene = (readManifest(_manifestFile)['moments']! as Map)[moment];
    if (scene == null) throw MomentsError('Unknown Moment: $moment; use moments list');
    return (scene as Map).cast();
  }

  /// The declared ancestry of [moment], root first.
  List<String> path(String moment) {
    final moments = readManifest(_manifestFile)['moments']! as Map;
    final out = <String>[];
    for (String? current = moment; current != null; current = (moments[current] as Map?)?['from'] as String?) {
      if (!moments.containsKey(current) || out.contains(current)) throw MomentsError('Unknown Moment: $current');
      out.insert(0, current);
    }
    return out;
  }

  Future<Map<String, Object?>> _projection(String recipe, Map<String, Object?> launch) async {
    final data = await call(recipe, 'project', {'launch': launch});
    final observed = recipe == explorations
        ? null
        : await call(recipe, 'observe', {'launch': launch, 'projection': <String, Object?>{}});
    final ids = <String, String>{};
    return {
      'recipe': data['recipe'],
      'data': normalize({'tables': data['tables'], 'history': data['history']}, ids),
      'observe': normalize(observed, ids),
    };
  }

  Map<String, Object?> _record(
    Map<String, Map<String, Object?>> situations,
    String moment, {
    required String recipe,
    required Map<String, Object?> launch,
    required Map<String, Object?> projection,
    required String kind,
    String? origin,
  }) {
    var n = 1;
    while (situations.containsKey('$moment@$n')) {
      n++;
    }
    final id = '$moment@$n';
    situations[id] = {
      'id': id,
      'moment': moment,
      'kind': kind,
      'recipe': recipe,
      'launch': launch,
      'origin': ?origin,
      'backend': backendVersion(),
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'projection': projection,
    };
    return situations[id]!;
  }

  Map<String, Object?> _public(Map<String, Object?> record) => {
    for (final key in const ['id', 'moment', 'kind', 'origin', 'backend', 'createdAt'])
      if (record[key] != null) key: record[key],
    'recipe': (record['projection'] as Map?)?['recipe'],
  };

  Transition _transition(String recipe) => Transition(
    prepare: ({parent, snapshot}) => call(recipe, 'prepare', {
      'context': {...context, 'parent': ?parent},
      if (snapshot != null) 'from': {'snapshot': snapshot},
    }),
    describe: ({snapshot}) async {
      final answer = await call(recipe, 'describe', {'snapshot': ?snapshot});
      return (
        isolated: answer['dataScope'] == true,
        digest: answer['recipe'] as String?,
        snapshot: answer['snapshot'] == true,
      );
    },
    capture: (launch, snapshot) => call(recipe, 'capture', {'launch': launch, 'snapshot': snapshot}),
  );

  /// [moment] evaluated now, in a data scope of its own: its recipe's
  /// `prepare` (a child's on its parent's checkpoint, [composeChain]), or a
  /// saved exploration's replay.
  Future<Map<String, Object?>> prepare(String moment) async {
    final String recipe;
    final Map<String, Object?> launch;
    if (explorationOf(_scene(moment)) case final exploration?) {
      recipe = explorations;
      launch = await call(explorations, 'replay', {'trace': exploration['trace']});
    } else {
      final backend = _scene(moment)['backend'];
      if (backend is! Map || backend['recipe'] is! String) {
        throw MomentsError('$moment has no backend recipe to evaluate');
      }
      recipe = backend['recipe']! as String;
      final moments = readManifest(_manifestFile)['moments']! as Map;
      final composed = await composeChain([
        for (final name in path(moment))
          (
            moment: name,
            identity: preparedIdentity(moments, name) ?? const {},
            transition: switch (((moments[name] as Map)['backend'] as Map?)?['recipe']) {
              final String own => _transition(own),
              _ => null,
            },
            parent: moments.values.any((scene) => (scene as Map)['from'] == name),
          ),
      ], CheckpointStore(p.join(project, 'moments/.backend/checkpoints.json')));
      launch = composed.launch ?? const {};
    }
    if (launch['dataScope'] is! String) {
      throw MomentsError(
        '$moment prepares on the shared database; fork, diff and trace need its recipe declared with data_scope: true',
      );
    }
    final projection = await _projection(recipe, launch);
    final situations = _read();
    final record = _record(
      situations,
      moment,
      recipe: recipe,
      launch: launch,
      projection: projection,
      kind: 'prepared',
    );
    _write(situations);
    return record;
  }

  /// `fork <moment> -n N`: the Moment prepared once and its whole data
  /// situation cloned [n] times; each copy writes only to itself.
  Future<Map<String, Object?>> fork(String moment, int n) async {
    if (n < 1 || n > 16) throw const MomentsError('fork takes -n from 1 to 16');
    final origin = await prepare(moment);
    final recipe = origin['recipe']! as String;
    final answer = await call(recipe, 'fork', {'launch': origin['launch'], 'n': n});
    final launches = answer['launches'];
    if (launches is! List ||
        launches.length != n ||
        launches.any(
          (l) => l is! Map || l['dataScope'] is! String || l['dataScope'] == (origin['launch']! as Map)['dataScope'],
        ) ||
        launches.map((l) => (l as Map)['dataScope']).toSet().length != n) {
      throw const MomentsError('The backend did not answer independent forks');
    }
    final forks = <Map<String, Object?>>[];
    for (final launch in launches.cast<Map>()) {
      final cast = launch.cast<String, Object?>();
      forks.add({'launch': cast, 'projection': await _projection(recipe, cast)});
    }
    final situations = _read();
    final records = [
      for (final fork in forks)
        _record(
          situations,
          moment,
          recipe: recipe,
          launch: fork['launch']! as Map<String, Object?>,
          projection: fork['projection']! as Map<String, Object?>,
          kind: 'fork',
          origin: origin['id']! as String,
        ),
    ];
    _write(situations);
    return {
      'moment': moment,
      'origin': _public(origin),
      'forks': [for (final record in records) _public(record)],
      'layers': ['data', 'observe'],
      'scope':
          'Each fork is a database cloned from the same snapshot of the prepared Moment; the UI projection and knob scopes are not forked',
    };
  }

  /// A situation by id, or [name] evaluated now when it names a Moment.
  Future<Map<String, Object?>> _resolve(String name) async {
    if (!situationId.hasMatch(name)) return prepare(name);
    final record = _read()[name];
    if (record == null) throw MomentsError('Unknown situation $name; moments situations lists them');
    return record;
  }

  /// The projection of [record] as it is now when its scope is still open,
  /// else the one captured when it was made. Either way the recipe digest
  /// is the one it was made with.
  Future<({Map<String, Object?> projection, String source})> _current(Map<String, Object?> record) async {
    final captured = (record['projection']! as Map).cast<String, Object?>();
    try {
      final live = await _projection(record['recipe']! as String, (record['launch']! as Map).cast());
      return (projection: {...live, 'recipe': captured['recipe']}, source: 'live');
    } on MomentsError {
      return (projection: captured, source: 'captured');
    }
  }

  /// `diff <a> <b>`: the normalized difference per layer, and whether the
  /// two were made under the same code and the same recipe.
  Future<Map<String, Object?>> diff(String a, String b) async {
    final first = await _resolve(a);
    final second = a == b ? first : await _resolve(b);
    final left = await _current(first), right = a == b ? left : await _current(second);
    final difference = diffProjections(left.projection, right.projection);
    final sameMoment = first['moment'] == second['moment'];
    final redefined = sameMoment && left.projection['recipe'] != right.projection['recipe'];
    return {
      'a': {..._public(first), 'source': left.source},
      'b': {..._public(second), 'source': right.source},
      'status': difference['empty'] == true ? 'same' : 'different',
      'comparison': !sameMoment
          ? 'across-moments'
          : first['backend'] != second['backend']
          ? 'across-versions'
          : 'same-version',
      'redefined': redefined,
      if (redefined)
        'meaning': 'The recipe changed between the two: differences are a redefined Moment, not changed behaviour',
      'layers': {'data': difference['data'], 'observe': difference['observe']},
      'normalization': normalization,
    };
  }

  /// `trace <moment>`: the declared path from the root, and the Moment
  /// evaluated from the empty database, every recorded change in order.
  Future<Map<String, Object?>> trace(String moment) async {
    final ancestry = path(moment);
    final record = await prepare(moment);
    final projection = (record['projection']! as Map).cast<String, Object?>();
    final data = (projection['data']! as Map).cast<String, Object?>();
    final steps = [
      for (final (index, entry) in ((data['history'] as List?) ?? const []).cast<Map>().indexed)
        {
          'step': index + 1,
          'subject': entry['subject'],
          'action': entry['action'],
          'verb': ?entry['verb'],
          'actor': entry['actorKind'],
          'outcome': entry['outcome'],
          'changes': {
            for (final field in {
              ...((entry['before'] as Map?) ?? const {}).keys,
              ...((entry['after'] as Map?) ?? const {}).keys,
            })
              '$field': [(entry['before'] as Map?)?[field], (entry['after'] as Map?)?[field]],
          },
        },
    ];
    return {
      'moment': moment,
      'path': ancestry,
      'situation': _public(record),
      'root': 'the migrated, empty database (Mana.Snapshot base)',
      'steps': steps,
      'tables': data['tables'],
      'observe': projection['observe'],
      'normalization': normalization,
    };
  }

  /// `save <trace> <name>`: an exploration trace (`Mana.Explore.save/3`),
  /// once it replays, is written where the Ash declaration lists
  /// explorations ([explorationDirectory]) and exported ([sync]): a Moment
  /// of the manifest, which the suite checks.
  Future<Map<String, Object?>> save(String file, String name) async {
    if (!_name.hasMatch(name)) throw const MomentsError('A Moment name is lowercase letters, digits and -');
    if ((readManifest(_manifestFile)['moments']! as Map).containsKey(name)) {
      throw MomentsError('$name already names a Moment');
    }
    final Object? trace;
    try {
      trace = jsonDecode(File(file).readAsStringSync());
    } on Object {
      throw MomentsError('Cannot read an exploration trace from $file');
    }
    if (trace is! Map ||
        trace['moves'] is! List ||
        trace['property'] is! String ||
        (trace['moves'] as List).any((move) => move is! Map || move['kind'] is! String)) {
      throw const MomentsError('Not an exploration trace (Mana.Explore.save/3 writes one)');
    }
    final cast = trace.cast<String, Object?>();
    final directory = explorationDirectory(project, _manifestFile, cast);
    final launch = await call(explorations, 'replay', {'trace': trace});
    if (launch['dataScope'] is! String) throw const MomentsError('The backend did not replay the exploration');
    final target = writeExploration(directory, name, cast);
    await sync();
    if (explorationOf((readManifest(_manifestFile)['moments']! as Map)[name]) == null) {
      throw MomentsError('$target is written, but the exported declaration does not list $name as an exploration');
    }
    writeExplorationMap(project);
    final projection = await _projection(explorations, launch);
    final situations = _read();
    final record = _record(
      situations,
      name,
      recipe: explorations,
      launch: launch,
      projection: projection,
      kind: 'exploration',
    );
    _write(situations);
    return {
      'moment': name,
      'trace': p.relative(target, from: project),
      'map': p.relative(mapFile, from: project),
      'situation': _public(record),
      'moves': (trace['moves'] as List).length,
    };
  }

  /// Every kept situation, newest last, without launches.
  List<Map<String, Object?>> list() {
    final records = _read().values.toList()..sort((a, b) => '${a['createdAt']}'.compareTo('${b['createdAt']}'));
    return [for (final record in records) _public(record)];
  }
}
