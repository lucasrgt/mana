import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';
import 'manifest.dart';

/// A glob over repository-relative paths: `**` crosses directories, `*` and
/// `?` stay inside one segment, `{a,b}` is an alternation.
RegExp globPattern(String glob) {
  final out = StringBuffer('^');
  var depth = 0;
  for (var i = 0; i < glob.length; i++) {
    final c = glob[i];
    if (c == '*') {
      if (i + 1 < glob.length && glob[i + 1] == '*') {
        i++;
        if (i + 1 < glob.length && glob[i + 1] == '/') {
          i++;
          out.write('(?:.*/)?');
        } else {
          out.write('.*');
        }
      } else {
        out.write('[^/]*');
      }
    } else if (c == '?') {
      out.write('[^/]');
    } else if (c == '{') {
      depth++;
      out.write('(?:');
    } else if (c == '}' && depth > 0) {
      depth--;
      out.write(')');
    } else if (c == ',' && depth > 0) {
      out.write('|');
    } else {
      out.write(RegExp.escape(c));
    }
  }
  if (depth != 0) throw ManaFailure('Unbalanced braces in glob: $glob');
  out.write(r'$');
  return RegExp(out.toString());
}

typedef Feature = ({
  String name,
  String description,
  List<String> paths,
  List<String> moments,
});

final class FeatureMap {
  FeatureMap._(this.root, this.roots, this.features);

  final String root;
  final List<String> roots;
  final List<Feature> features;

  static const file = 'features.toml';

  static FeatureMap? tryLoad(String root) =>
      File(p.join(root, file)).existsSync() ? load(root) : null;

  static FeatureMap load(String root) {
    final Map<String, Object?> data;
    try {
      data = TomlDocument.parse(
        File(p.join(root, file)).readAsStringSync(),
      ).toMap();
    } on TomlException catch (error) {
      throw ManaFailure('Invalid $file: $error');
    } on FileSystemException {
      throw ManaFailure('Missing $file: declare the project features first');
    }
    if (data['version'] != 1) {
      throw const ManaFailure('Unsupported features.toml version');
    }
    List<String> strings(Object? value, String where) {
      if (value is! List || value.any((v) => v is! String)) {
        throw ManaFailure('$where must be a list of strings');
      }
      return value.cast<String>();
    }

    final declared = data['features'];
    if (declared is! Map || declared.isEmpty) {
      throw const ManaFailure('features.toml declares no features');
    }
    final features = <Feature>[
      for (final MapEntry(:key, :value) in declared.entries)
        if (value is Map)
          (
            name: key as String,
            description: (value['description'] ?? '') as String,
            paths: strings(
              value['paths'] ?? const <String>[],
              'features."$key".paths',
            ),
            moments: strings(
              value['moments'] ?? const <String>[],
              'features."$key".moments',
            ),
          )
        else
          throw ManaFailure('features."$key" must be a table'),
    ];
    for (final feature in features) {
      if (!RegExp(
        r'^[a-z0-9][a-z0-9-]*(/[a-z0-9][a-z0-9-]*)*$',
      ).hasMatch(feature.name)) {
        throw ManaFailure('Invalid feature name: ${feature.name}');
      }
      for (final glob in [...feature.paths]) {
        globPattern(glob);
      }
      for (final ref in feature.moments) {
        if (!ref.contains(':')) {
          throw ManaFailure('Moment reference must be <app>:<glob>: $ref');
        }
      }
    }
    return FeatureMap._(
      root,
      strings(data['roots'] ?? const <String>[], 'roots'),
      features,
    );
  }

  late final _compiled = {
    for (final feature in features)
      feature.name: [for (final glob in feature.paths) globPattern(glob)],
  };

  Feature named(String name) =>
      features.where((f) => f.name == name).firstOrNull ??
      (throw ManaFailure('Unknown feature: $name'));

  List<String> owners(String path) => [
    for (final feature in features)
      if (_compiled[feature.name]!.any((glob) => glob.hasMatch(path)))
        feature.name,
  ];

  /// Tracked files (git), or every file below the root when it is not a work tree.
  late final List<String> files = () {
    final git = Process.runSync('git', [
      'ls-files',
      '-z',
    ], workingDirectory: root);
    if (git.exitCode == 0) {
      return (git.stdout as String)
          .split('\x00')
          .where((path) => path.isNotEmpty)
          .toList()
        ..sort();
    }
    return [
      for (final entity in Directory(
        root,
      ).listSync(recursive: true, followLinks: false))
        if (entity is File) p.relative(entity.path, from: root),
    ]..sort();
  }();

  late final List<RegExp> _roots = [
    for (final glob in roots) globPattern(glob),
  ];

  bool inRoots(String path) => _roots.any((glob) => glob.hasMatch(path));

  /// Moment names per app, read from each product frontend's Moments manifest.
  late final Map<String, List<String>> momentCatalog = () {
    final catalog = <String, List<String>>{};
    final Map<String, Object?> config;
    try {
      config = readManifest(root);
    } on ManaFailure {
      return catalog;
    }
    final products = (config['products'] as Map?) ?? const {};
    for (final product in products.values.whereType<Map>()) {
      for (final frontend in frontends(product.cast())) {
        final manifest = File(p.join(root, frontend, 'moments/manifest.json'));
        if (!manifest.existsSync()) continue;
        final moments =
            (jsonDecode(manifest.readAsStringSync()) as Map)['moments'];
        if (moments is Map) {
          catalog[p.basename(frontend)] = moments.keys.cast<String>().toList()
            ..sort();
        }
      }
    }
    return catalog;
  }();

  List<String> moments(Feature feature) => [
    for (final ref in feature.moments)
      for (final MapEntry(key: app, value: names) in momentCatalog.entries)
        if (globPattern(ref.substring(0, ref.indexOf(':'))).hasMatch(app))
          for (final name in names)
            if (globPattern(ref.substring(ref.indexOf(':') + 1)).hasMatch(name))
              '$app:$name',
  ].toSet().toList()..sort();

  Map<String, Object?> describe(Feature feature) => {
    'name': feature.name,
    'address': 'feature:${feature.name}',
    'description': feature.description,
    'files': [
      for (final path in files)
        if (_compiled[feature.name]!.any((glob) => glob.hasMatch(path))) path,
    ],
    'moments': moments(feature),
  };

  /// Unowned files under the roots, globs that match nothing, and moment
  /// references that match no declared Moment.
  Map<String, Object?> check() {
    final unowned = [
      for (final path in files)
        if (inRoots(path) && owners(path).isEmpty) path,
    ];
    final stalePaths = [
      for (final feature in features)
        for (final (index, glob) in _compiled[feature.name]!.indexed)
          if (!files.any(glob.hasMatch))
            '${feature.name}: ${feature.paths[index]}',
    ];
    final staleMoments = momentCatalog.isEmpty
        ? const <String>[]
        : [
            for (final feature in features)
              for (final ref in feature.moments)
                if (moments((
                  name: feature.name,
                  description: '',
                  paths: const [],
                  moments: [ref],
                )).isEmpty)
                  '${feature.name}: $ref',
          ];
    return {
      'status': unowned.isEmpty && stalePaths.isEmpty && staleMoments.isEmpty
          ? 'passed'
          : 'failed',
      'features': features.length,
      'files': files.where(inRoots).length,
      'unowned': unowned,
      'stalePaths': stalePaths,
      'staleMoments': staleMoments,
    };
  }

  /// Feature, verb and Moment in one map: per feature, the verbs that name it
  /// (`x-mana-verbs` in [contracts]), its Moments and the sensors that cover
  /// it ([sensorCovers], each sensor's `covers`), and the gaps — verbs no
  /// Moment of their feature exercises, features with Moments but no verbs,
  /// verbs that name an undeclared feature and verbs that name none.
  Map<String, Object?> coverage(
    Iterable<Object?> contracts, {
    Map<String, List<String>> sensorCovers = const {},
    String? only,
  }) {
    final verbs = <String, List<String>>{};
    final unknown = <String>[];
    final homeless = <String>[];
    final names = {for (final f in features) f.name};
    for (final contract in contracts) {
      final schemas =
          ((contract as Map?)?['components'] as Map?)?['schemas'] as Map? ??
          const {};
      for (final MapEntry(key: type, :value) in schemas.entries) {
        if (value is! Map || value['x-mana-verbs'] is! List) continue;
        for (final verb in (value['x-mana-verbs'] as List).cast<Map>()) {
          final address = '$type.${verb['name']}';
          final feature = verb['feature'];
          if (feature is! String) {
            homeless.add(address);
          } else if (!names.contains(feature)) {
            unknown.add('$address → feature:$feature');
          } else {
            (verbs[feature] ??= []).add(address);
          }
        }
      }
    }
    final rows = [
      for (final feature in features)
        if (only == null || feature.name == only)
          {
            'feature': feature.name,
            'verbs': [...?verbs[feature.name]]..sort(),
            'moments': moments(feature),
            'sensors': [
              for (final MapEntry(key: id, value: covers)
                  in sensorCovers.entries)
                if (covers.contains('feature:${feature.name}')) id,
            ],
          },
    ];
    final unexercised = [
      for (final row in rows)
        if ((row['moments'] as List).isEmpty)
          for (final verb in row['verbs'] as List) verb,
    ];
    final verbless = [
      for (final row in rows)
        if ((row['verbs'] as List).isEmpty &&
            (row['moments'] as List).isNotEmpty)
          row['feature'],
    ];
    return {
      'status': unexercised.isEmpty && unknown.isEmpty && homeless.isEmpty
          ? 'passed'
          : 'gaps',
      'features': rows,
      'unexercisedVerbs': unexercised,
      'featuresWithoutVerbs': verbless,
      'verbsWithUnknownFeature': unknown..sort(),
      'verbsWithoutFeature': homeless..sort(),
    };
  }

  /// Features touched by the changes since [base] (committed and uncommitted).
  Map<String, Object?> changed(String base) {
    final diff = Process.runSync('git', [
      'diff',
      '--name-only',
      base,
      '--',
    ], workingDirectory: root);
    if (diff.exitCode != 0) throw ManaFailure('Cannot diff against $base');
    final untracked = Process.runSync('git', [
      'ls-files',
      '--others',
      '--exclude-standard',
    ], workingDirectory: root);
    final paths = {
      ...(diff.stdout as String).split('\n'),
      ...(untracked.stdout as String).split('\n'),
    }.where((path) => path.isNotEmpty).toList()..sort();
    final byFeature = <String, List<String>>{};
    final unowned = <String>[];
    for (final path in paths) {
      final names = owners(path);
      if (names.isEmpty && inRoots(path)) unowned.add(path);
      for (final name in names) {
        (byFeature[name] ??= []).add(path);
      }
    }
    return {
      'base': base,
      'features': [
        for (final MapEntry(:key, :value)
            in (byFeature.entries.toList()
              ..sort((a, b) => a.key.compareTo(b.key))))
          {'name': key, 'files': value, 'moments': moments(named(key))},
      ],
      'unowned': unowned,
    };
  }
}
