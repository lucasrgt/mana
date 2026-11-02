import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'declaration_sources.dart';
import 'effects.dart';
import 'errors.dart';
import 'impact.dart';
import 'journey.dart' show criteria;
import 'json.dart';
import 'manifest.dart';

bool _inside(String root, String file) {
  final path = p.relative(file, from: root);
  return path != '..' && !path.startsWith('../') && !p.isAbsolute(path);
}

String _git(String root, List<String> args) {
  final result = Process.runSync('git', ['-C', root, ...args], stdoutEncoding: utf8);
  if (result.exitCode != 0) throw MomentsError('git ${args.first} failed');
  return result.stdout as String;
}

List<String> _changes(String root, String base) {
  // --no-renames includes both the deleted source and added destination. NUL
  // delimiters preserve spaces/newlines, unlike parsing porcelain line output.
  final tracked = _git(root, ['diff', '--no-ext-diff', '--name-only', '--no-renames', '-z', base, '--']);
  final untracked = _git(root, ['ls-files', '--others', '--exclude-standard', '-z']);
  final files = '$tracked$untracked'.split('\x00').where((f) => f.isNotEmpty).toSet().toList()..sort();
  if (files.length > 20000) throw const MomentsError('Change inventory exceeds 20000 files; select a closer Git base.');
  return files;
}

// A change can reach an app only through its own tree, the local Dart
// packages it resolves and its declared backend roots. Without a resolved
// package configuration nothing is narrowed.
List<String>? _reachableRoots(String project) {
  final Map config;
  try {
    config = jsonDecode(File(p.join(project, '.dart_tool/package_config.json')).readAsStringSync()) as Map;
  } on Object {
    return null;
  }
  final base = Uri.directory(p.join(project, '.dart_tool'));
  final roots = <String>[project];
  for (final entry in ((config['packages'] as List?) ?? const []).cast<Map>()) {
    final uri = base.resolve(entry['rootUri'] as String);
    if (uri.scheme == 'file') roots.add(p.fromUri(uri));
  }
  try {
    final sources = jsonDecode(File(p.join(project, 'moments/sources.json')).readAsStringSync()) as Map;
    for (final entry in ((sources['roots'] as List?) ?? const []).cast<Map>()) {
      roots.add(p.normalize(p.join(project, entry['path'] as String)));
    }
  } on Object {
    // No declared sibling roots.
  }
  return [
    for (final root in roots)
      if (Directory(root).existsSync()) Directory(root).resolveSymbolicLinksSync(),
  ];
}

Map<String, Object?> _screen(Map<String, Object?> manifest, Map<String, Object?> scene) {
  final screens = manifest['screens'] as Map?;
  final result = screens != null ? screens[(scene['projection'] as Map?)?['route']] as Map? : manifest;
  if (result == null || result['watch'] is! List || result['properties'] == null) {
    throw const MomentsError('Moment has no valid screen declaration; run moments sync.');
  }
  return {
    'properties': result['properties'],
    'watch': result['watch'],
    'clientRoots': result['clientRoots'] ?? <Object?>[],
  };
}

Map<String, Object?> _identity(Map<String, Object?> manifest, Map<String, Object?> scene) => {
  'scene': scene,
  'screen': _screen(manifest, scene),
};

List<String> _validNames(Map<String, Object?> manifest) {
  final names = ((manifest['moments'] as Map?) ?? const {}).keys.cast<String>().toList()..sort();
  if (names.isEmpty || names.any((name) => !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name))) {
    throw const MomentsError('Invalid Moment catalog; run moments sync.');
  }
  return names;
}

Map<String, Object?> _scene(Map<String, Object?> manifest, String name) =>
    ((manifest['moments']! as Map)[name]! as Map).cast();

// One Moment selected for two kinds of evidence: Dart with Elixir is a
// union; the compiled file graph is the wider of the two Elixir reasons.
String _combined(String a, String b) {
  if (a == b) return a;
  if ({a, b}.any((r) => r.startsWith('dart-')) || {a, b}.contains('dart-and-elixir-dependency')) {
    return 'dart-and-elixir-dependency';
  }
  return {a, b}.contains('elixir-compiled-dependency') ? 'elixir-compiled-dependency' : 'elixir-action-effect';
}

/// Read-only selection. A plan is never a test result or permission to
/// replay. Dart narrowing requires stable declared roots and a current import
/// graph. Elixir narrowing requires fresh compiled evidence with unchanged
/// topology. watch is a refresh inventory, not proof of a complete dependency
/// graph.
Future<Map<String, Object?>> affectedMoments(String project, {String base = 'HEAD'}) async {
  project = Directory(project).resolveSymbolicLinksSync();
  final String root, commit;
  try {
    root = Directory(_git(project, ['rev-parse', '--show-toplevel']).trim()).resolveSymbolicLinksSync();
    commit = _git(root, ['rev-parse', '--verify', '--end-of-options', '$base^{commit}']).trim();
  } on Object {
    throw const MomentsError('A valid Git checkout and commit base are required for moments affected.');
  }
  if (!_inside(root, project)) throw const MomentsError('The selected app must belong to the Git checkout.');
  final manifestFile = p.join(project, 'moments/manifest.json');
  final text = File(manifestFile).readAsStringSync();
  final manifest = readManifest(manifestFile);
  final names = _validNames(manifest);
  final inventory = _changes(root, commit), manifestPath = p.relative(manifestFile, from: root);
  final reachable = _reachableRoots(project);
  // Only changes that belong to another project of the checkout (a directory
  // with its own package manifest the app does not resolve) are out of reach.
  // Repository-level files have no such owner and still widen the plan.
  final manifests = RegExp(r'^(pubspec\.yaml|mix\.exs|package\.json|go\.mod|Cargo\.toml|pyproject\.toml|.+\.csproj)$');
  final ownerCache = <String, String?>{};
  String? owner(String dir) {
    if (dir == root || !_inside(root, dir)) return null;
    if (!ownerCache.containsKey(dir)) {
      var entries = <String>[];
      try {
        entries = [for (final entry in Directory(dir).listSync()) p.basename(entry.path)];
      } on Object {
        entries = const [];
      }
      ownerCache[dir] = entries.any(manifests.hasMatch) ? dir : owner(p.dirname(dir));
    }
    return ownerCache[dir];
  }

  bool reaches(String file) {
    final fileOwner = owner(p.dirname(file));
    if (reachable!.any((base) => _inside(base, file))) {
      return fileOwner == null || reachable.contains(fileOwner) || !_inside(project, fileOwner);
    }
    return fileOwner == null;
  }

  final paths = reachable != null ? inventory.where((path) => reaches(p.join(root, path))).toList() : inventory;
  final declarations = <String>{};
  final issues = <Map<String, Object?>>[];
  for (final name in names) {
    _screen(manifest, _scene(manifest, name));
    try {
      final source = declarationSource(project, manifestFile, _scene(manifest, name)['source']);
      if (source['status'] != 'current') issues.add({'name': name, 'reason': 'stale-declaration'});
      // A source co-located with a backend resource also carries runtime
      // behaviour: never narrow a change there from declaration metadata alone.
      if (_inside(p.join(project, 'moments'), source['absolute']! as String)) {
        declarations.add(p.relative(source['absolute']! as String, from: root));
      }
    } on Object {
      issues.add({'name': name, 'reason': 'unavailable-declaration'});
    }
  }
  Map<String, Object?>? previous;
  try {
    previous = (jsonDecode(_git(root, ['show', '$commit:$manifestPath'])) as Map).cast();
    if (![1, 2, 3].contains(previous['version'])) throw const MomentsError('Unsupported base manifest');
    for (final name in _validNames(previous)) {
      _identity(previous, _scene(previous, name));
    }
  } on Object {
    previous = null;
  }
  final reasons = <Map<String, Object?>>[];
  final selected = <String, String>{};
  // Why each Moment is selected, in words: import, compiled dependency,
  // effect: <Resource.action>, no receipt, or the widening reason.
  final why = <String, Set<String>>{};
  void all(String code, [List<String> files = const []]) {
    reasons.add({'code': code, 'paths': files});
    for (final name in names) {
      selected[name] = code;
      why.putIfAbsent(name, () => {}).add(code);
    }
  }

  void mark(String name, String reason, Iterable<String> labels) {
    final existing = selected[name];
    selected[name] = existing == null ? reason : _combined(existing, reason);
    why.putIfAbsent(name, () => {}).addAll(labels);
  }

  if (issues.isNotEmpty) all('sync-required');
  if (previous == null) all('catalog-missing-at-base', [manifestPath]);
  final runtimePaths = paths.where((path) => path != manifestPath && !declarations.contains(path)).toList();
  Map<String, Object?>? dartGraph, backendGraph, effectGraph;
  Map<String, Object?>? include(Impact graph, List<String> files, String reason, String label) {
    final unmapped = files.where((path) => !graph.owners.containsKey(path)).toList();
    if (unmapped.isNotEmpty) {
      all('runtime-or-unmapped-change', unmapped);
      return null;
    }
    // Keep every graph's evidence. Union, never intersection: a shared or
    // unavailable side must not be narrowed by a more precise other side.
    if (reasons.isEmpty) {
      for (final path in files) {
        for (final name in graph.owners[path]!) {
          mark(name, reason, [label]);
        }
      }
    }
    return impactJson(graph, files);
  }

  // A file only backend mutations reach selects the Moments whose evidence
  // names one of them, and every Moment whose evidence is incomplete.
  Map<String, Object?> byEffect(ActionMap map, List<String> files) {
    final reached = {for (final path in files) ...map.effects[path]!};
    final evidence = effectEvidence(
      manifest,
      map,
      latestReceipts(project),
      reached,
      preparations: latestPreparations(project),
    );
    if (reasons.isEmpty) {
      for (final name in names) {
        final (:hits, :missing) = evidence[name]!;
        if (hits.isNotEmpty) {
          mark(name, 'elixir-action-effect', [for (final action in hits.toList()..sort()) 'effect: $action']);
        } else if (missing != null) {
          mark(name, 'elixir-effect-evidence-missing', [missing]);
        }
      }
    }
    return {
      'status': 'available',
      'scope':
          'Files only create, update and destroy actions reach, matched with the actions named by each Moment\'s step verbs, recipe preparations (observed, else statically reached resources), exploration traces and latest passed receipts',
      'matches': [
        for (final path in files)
          {
            'path': path,
            'actions': map.effects[path],
            'moments': [
              for (final name in names)
                if (evidence[name]!.hits.any(map.effects[path]!.contains)) name,
            ],
          },
      ],
      'evidenceMissing': {
        for (final name in names)
          if (evidence[name]!.hits.isEmpty && evidence[name]!.missing != null) name: evidence[name]!.missing,
      },
    };
  }

  if (runtimePaths.isNotEmpty) {
    final entries = {
      for (final name in names)
        name: ((_screen(manifest, _scene(manifest, name))['clientRoots']! as List).cast<String>()),
    };
    final stableRoots =
        previous != null &&
        names.every(
          (name) =>
              entries[name]!.isNotEmpty &&
              (previous!['moments']! as Map).containsKey(name) &&
              jsonEqual(entries[name], _screen(previous, _scene(previous, name))['clientRoots']),
        );
    final appLibrary = '${p.relative(p.join(project, 'lib'), from: root)}/';
    final dartPaths = runtimePaths.where((path) => path.startsWith(appLibrary) && path.endsWith('.dart')).toList();
    final dartSet = dartPaths.toSet();
    final packages = (reachable ?? const <String>[])
        .where((base) => base != project && File(p.join(base, 'pubspec.yaml')).existsSync())
        .toList();
    final sharedPaths = runtimePaths
        .where((path) => !dartSet.contains(path) && packages.any((base) => _inside(base, p.join(root, path))))
        .toList();
    if (sharedPaths.isNotEmpty) all('shared-dart-package-change', sharedPaths);
    final sharedSet = sharedPaths.toSet();
    final backendPaths = runtimePaths.where((path) => !dartSet.contains(path) && !sharedSet.contains(path)).toList();
    if (dartPaths.isNotEmpty) {
      // Shared package bodies remain global because hosted dependencies can
      // reach local overrides outside the parsed app composition boundaries.
      if (issues.isEmpty && stableRoots) {
        try {
          dartGraph = include(
            await dartImpact(project, root, entries, (manifest['watch']! as List).cast<String>()),
            dartPaths,
            'dart-import-dependency',
            'import',
          );
        } on Object {
          all('dart-impact-unavailable', dartPaths);
        }
      } else {
        all('runtime-or-unmapped-change', dartPaths);
      }
    }
    if (backendPaths.isNotEmpty) {
      if (issues.isEmpty &&
          previous != null &&
          stableBackendGraph(manifest['backendGraph'], previous['backendGraph'])) {
        try {
          final graph = (manifest['backendGraph']! as Map).cast<String, Object?>();
          final impact = backendImpact(project, root, manifestFile, manifest, previous);
          final effects = actionMap(
            graph,
            ((graph['files']! as Map).keys.cast<String>()).toSet(),
            (file) => p.relative(p.normalize(p.join(p.dirname(manifestFile), file)), from: root),
          );
          final effectPaths = [
            if (effects != null)
              for (final path in backendPaths)
                if (effects.effects.containsKey(path)) path,
          ];
          backendGraph = include(
            impact,
            [
              for (final path in backendPaths)
                if (!effectPaths.contains(path)) path,
            ],
            'elixir-compiled-dependency',
            'compiled dependency',
          );
          effectGraph = effects == null
              ? {'status': 'unavailable', 'reason': 'No action map in the backend graph; run moments sync'}
              : effectPaths.isEmpty
              ? null
              : byEffect(effects, effectPaths);
        } on Object {
          all('backend-impact-unavailable', backendPaths);
        }
      } else {
        all('runtime-or-unmapped-change', backendPaths);
      }
    }
  }
  final removed = previous == null
      ? <String>[]
      : ((previous['moments']! as Map).keys
            .cast<String>()
            .where((name) => !(manifest['moments']! as Map).containsKey(name))
            .toList()
          ..sort());
  if (removed.isNotEmpty) all('catalog-removal');
  if (previous != null) {
    // Unknown/new manifest-level capabilities cannot be silently ignored.
    const local = [
      'moments',
      'screens',
      'properties',
      'watch',
      'recipeHash',
      'domain',
      'generator',
      'clientRoots',
      'backendGraph',
    ];
    Map<String, Object?> global(Map<String, Object?> value) =>
        canonical({
              for (final MapEntry(:key, :value) in value.entries)
                if (!local.contains(key)) key: value,
            })!
            as Map<String, Object?>;
    if (!jsonEqual(global(previous), global(manifest))) all('manifest-contract-change', [manifestPath]);
    if (!jsonEqual(canonical(previous['backendGraph']), canonical(manifest['backendGraph'])) &&
        !stableBackendGraph(manifest['backendGraph'], previous['backendGraph'])) {
      all('backend-topology-change', [manifestPath]);
    }
    if (!jsonEqual(previous['watch'], manifest['watch'])) all('refresh-inventory-change', [manifestPath]);
    bool sameIdentity(String name) =>
        (previous!['moments']! as Map).containsKey(name) &&
        jsonEqual(
          canonical(_identity(previous, _scene(previous, name))),
          canonical(_identity(manifest, _scene(manifest, name))),
        );
    for (final name in names) {
      if (!sameIdentity(name) && !selected.containsKey(name))
        mark(name, 'exported-declaration-change', ['declaration']);
    }
    // A changed declaration whose export did not change can contain helper
    // behaviour. Without a dependency graph its impact is unknown, not empty.
    for (final path in paths.where(declarations.contains)) {
      final owners = names.where((name) {
        final file = (_scene(manifest, name)['source'] as Map?)?['file'] as String?;
        return file != null && p.relative(p.normalize(p.join(p.dirname(manifestFile), file)), from: root) == path;
      }).toList();
      if (owners.isEmpty || owners.every(sameIdentity)) all('declaration-impact-unknown', [path]);
    }
  }
  if (File(manifestFile).readAsStringSync() != text)
    throw const MomentsError('Manifest changed while planning; run moments affected again.');
  String operation(String name) {
    final scene = _scene(manifest, name);
    final checks = ((scene['checks'] as List?) ?? const []).cast<Map>();
    if (((scene['steps'] as List?)?.length ?? 0) > 0) {
      return checks.any((c) => c['scope'] != 'step' && criteria.contains(c['kind'])) ? 'run' : 'navigate';
    }
    return checks.any((c) => c['scope'] != 'step') ? 'check' : 'navigate';
  }

  return {
    'version': 1,
    'status': issues.isNotEmpty ? 'unavailable' : 'planned',
    'exitCode': issues.isNotEmpty ? 2 : 0,
    'executed': false,
    'project': project,
    'base': {'requested': base, 'commit': commit},
    'changeScope':
        'Git base to working tree, including staged, unstaged and non-ignored untracked files${reachable != null ? ', ignoring other projects of the checkout the app does not resolve' : ''}',
    'ignoredChanges': inventory.length - paths.length,
    'precision': reasons.isNotEmpty
        ? 'whole-catalog'
        : dartGraph != null && backendGraph != null
        ? 'dart-and-elixir'
        : dartGraph != null
        ? 'dart-imports'
        : backendGraph != null && effectGraph?['status'] == 'available'
        ? 'elixir-effects'
        : backendGraph != null
        ? 'elixir-compiled'
        : selected.isNotEmpty
        ? 'exported-declarations'
        : 'unchanged',
    'dartGraph': ?dartGraph,
    'backendGraph': ?backendGraph,
    'effectGraph': ?effectGraph,
    'changed': paths,
    'reasons': reasons,
    'issues': issues,
    'removed': removed,
    'selected': [
      for (final name in selected.keys.toList()..sort())
        {'name': name, 'operation': operation(name), 'reason': selected[name], 'why': why[name]!.toList()},
    ],
    'omitted': [
      for (final name in names)
        if (!selected.containsKey(name)) name,
    ],
    'limitation':
        'Dart selection follows static imports from explicitly declared client roots, not dynamic calls. Elixir selection uses compiled file dependencies and reflected Ash resources with fresh hashes and unchanged topology; a file only create/update/destroy actions reach selects the Moments whose step verbs, recipes or latest passed receipts name those actions, and every Moment without that evidence. Receipts cover gesture requests only, not screen loads or jobs. Dynamic dispatch is outside both graphs. Shared packages, metadata, unavailable graphs and unmapped changes widen selection. Run/check/navigate still validate current sources and runtime independently; navigation is not verification.',
  };
}
