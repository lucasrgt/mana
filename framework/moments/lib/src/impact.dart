import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'dart_sources.dart';
import 'declaration_sources.dart';
import 'errors.dart';
import 'json.dart';
import 'paths.dart';

bool _inside(String root, String file) {
  final path = p.relative(file, from: root);
  return path != '..' && !path.startsWith('../') && !p.isAbsolute(path);
}

String _real(String path) => FileSystemEntity.isDirectorySync(path)
    ? Directory(path).resolveSymbolicLinksSync()
    : File(path).resolveSymbolicLinksSync();

typedef Impact = ({Map<String, Set<String>> owners, String identity, int fileCount, double elapsedMs, String scope});

Map<String, Object?> impactJson(Impact impact, List<String> files) => {
  'identity': impact.identity,
  'fileCount': impact.fileCount,
  'elapsedMs': impact.elapsedMs,
  'scope': impact.scope,
  'matches': [
    for (final path in files) {'path': path, 'moments': (impact.owners[path]!.toList()..sort())},
  ],
};

// --- The pinned Dart import parser (framework/flutter/devtools) ---

String _devtools() => p.join(p.dirname(momentsRoot()), 'flutter/devtools');

String _importsIdentity() {
  final version = Process.runSync('dart', ['--version']);
  if (version.exitCode != 0) throw const MomentsError('Dart SDK unavailable');
  final directory = _devtools();
  const files = ['bin/imports.dart', 'pubspec.yaml', 'pubspec.lock', '.dart_tool/package_config.json'];
  return hashText(
    jsonEncode({
      'sdk': '${version.stdout}${version.stderr}',
      'platform': Platform.operatingSystem,
      'abi': '${Abi.current()}',
      'files': [
        for (final path in files) [path, hashBytes(File(p.join(directory, path)).readAsBytesSync())],
      ],
    }),
  );
}

String importsBinary() {
  final directory = _devtools();
  final metadata = File(p.join(directory, '.dart_tool/mana-imports.json'));
  final binary = File(p.join(directory, '.dart_tool/mana-imports'));
  if (!metadata.existsSync() || !binary.existsSync()) throw const MomentsError('Mana import tool is missing; build it');
  final record = jsonDecode(metadata.readAsStringSync()) as Map;
  if (record['version'] != 1 ||
      record['identity'] != _importsIdentity() ||
      record['sha256'] != hashBytes(binary.readAsBytesSync())) {
    throw const MomentsError('Mana import tool is stale; rebuild it');
  }
  return binary.path;
}

Future<void> buildImportsTool() async {
  final directory = _devtools();
  final before = _importsIdentity();
  final binary = p.join(directory, '.dart_tool/mana-imports'), temp = '$binary.${uuidV4()}';
  try {
    final compile = await Process.start(
      'dart',
      ['compile', 'exe', 'bin/imports.dart', '-o', temp],
      workingDirectory: directory,
      mode: ProcessStartMode.inheritStdio,
    );
    if (await compile.exitCode != 0) throw const MomentsError('Dart import tool compilation failed');
    if (_importsIdentity() != before) throw const MomentsError('Import tool source changed during compilation');
    final metadata =
        '${const JsonEncoder.withIndent('  ').convert({'version': 1, 'identity': before, 'sha256': hashBytes(File(temp).readAsBytesSync())})}\n';
    File(temp).renameSync(binary);
    File('$binary.json.tmp')
      ..writeAsStringSync(metadata)
      ..renameSync(p.join(directory, '.dart_tool/mana-imports.json'));
    stdout.writeln('Built the pinned Dart import parser');
  } finally {
    if (File(temp).existsSync()) File(temp).deleteSync();
  }
}

/// A static dependency graph, not a call graph or a proof of behavioral
/// isolation. Unmapped files always widen; callers may never silently drop an
/// unknown delta.
Future<Impact> dartImpact(String project, String root, Map<String, List<String>> entries, List<String> watch) async {
  final clock = Stopwatch()..start();
  final inventory = DartSources(project, watch);
  final before = inventory.snapshot(fresh: true);
  final packages = inventory.localPackages();
  final locals = {for (final pkg in packages) pkg.name: pkg};
  final config = File(p.join(project, '.dart_tool/package_config.json'));
  if (!config.existsSync() || packages.isEmpty)
    throw const MomentsError('Resolved Pub project required for Dart impact');
  final known = {
    for (final entry in ((jsonDecode(config.readAsStringSync()) as Map)['packages'] as List).cast<Map>()) entry['name'],
  };
  final files = <String, String>{}, sources = <Map<String, Object?>>[];
  for (final MapEntry(:key, :value) in (before['files']! as Map).cast<String, String>().entries) {
    String file;
    if (key.startsWith('package:')) {
      final match = RegExp(r'^package:([^/]+)/(.+)$').firstMatch(key);
      final pkg = locals[match?[1]];
      if (pkg == null) throw const MomentsError('Unknown local package in source inventory');
      file = p.normalize(p.join(pkg.root, match![2]!));
    } else {
      file = p.normalize(p.join(project, key));
    }
    file = _real(file);
    if (!_inside(root, file)) throw const MomentsError('Local Dart source is outside the Git checkout');
    final bytes = File(file).readAsBytesSync();
    if (hashBytes(bytes) != value) throw const MomentsError('Dart source changed during graph capture');
    sources.add({'path': file, 'content': utf8.decode(bytes)});
    files[file] = p.relative(file, from: root);
  }
  final input = jsonEncode({'version': 1, 'files': sources});
  if (utf8.encode(input).length > 32 * 1024 * 1024)
    throw const MomentsError('Dart source graph exceeds its bounded input');
  final parser = await Process.start(importsBinary(), const []);
  final output = utf8.decoder.bind(parser.stdout).join();
  unawaited(parser.stderr.drain<void>());
  parser.stdin.write(input);
  await parser.stdin.close();
  final code = await parser.exitCode.timeout(
    const Duration(seconds: 30),
    onTimeout: () {
      parser.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
  if (code != 0)
    throw const MomentsError('Dart import graph unavailable; inspect syntax or the pinned devtools installation');
  final text = await output;
  final Map graph;
  try {
    graph = jsonDecode(text) as Map;
  } on FormatException {
    throw const MomentsError('Invalid Dart import graph response');
  }
  final nodes = graph['files'] as Map?;
  if (graph['version'] != 1 || nodes == null || nodes.length != files.length)
    throw const MomentsError('Incomplete Dart import graph');
  String? target(String file, Object? uri) {
    if (uri is! String || uri.isEmpty) throw const MomentsError('Invalid Dart directive');
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      final match = RegExp(r'^package:([^/]+)/(.+)$').firstMatch(uri);
      if (match == null || !known.contains(match[1])) throw const MomentsError('Unresolved Dart package import');
      final pkg = locals[match[1]];
      if (pkg == null) return null; // Hosted/SDK bodies are fixed by Pub metadata; a lock delta widens globally.
      final path = _real(p.normalize(p.join(pkg.library, match[2]!)));
      if (!_inside(pkg.library, path)) throw const MomentsError('Dart import escapes package library');
      return path;
    }
    final url = Uri.file(file).resolve(uri);
    if (url.scheme != 'file' || url.hasQuery || url.hasFragment)
      throw const MomentsError('Unsupported Dart directive URI');
    return _real(p.fromUri(url));
  }

  final edges = <String, List<String>>{};
  for (final MapEntry(key: file, value: uris) in nodes.cast<String, Object?>().entries) {
    if (!files.containsKey(file) || uris is! List) throw const MomentsError('Unexpected Dart import graph node');
    final dependencies = <String>{};
    for (final uri in uris) {
      final path = target(file, uri);
      if (path != null) {
        if (!files.containsKey(path)) throw const MomentsError('Dart dependency is outside the inventoried libraries');
        dependencies.add(path);
      }
    }
    edges[file] = dependencies.toList();
  }
  final owners = <String, Set<String>>{};
  for (final MapEntry(key: name, value: roots) in entries.entries) {
    if (roots.isEmpty) throw const MomentsError('Every Moment needs client roots to narrow Dart impact');
    final pending = [
      for (final path in roots)
        () {
          if (!RegExp(r'^lib/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+\.dart$').hasMatch(path))
            throw const MomentsError('Invalid Moment client root');
          return _real(p.join(project, path));
        }(),
    ];
    final seen = <String>{};
    while (pending.isNotEmpty) {
      final file = pending.removeLast();
      if (!seen.add(file)) continue;
      final dependencies = edges[file];
      if (dependencies == null) throw const MomentsError('Moment client root is outside the source inventory');
      owners.putIfAbsent(files[file]!, () => {}).add(name);
      pending.addAll(dependencies);
    }
  }
  if (inventory.snapshot(fresh: true)['digest'] != before['digest'])
    throw const MomentsError('Dart sources changed while planning; retry');
  return (
    owners: owners,
    identity: before['digest']! as String,
    fileCount: files.length,
    elapsedMs: clock.elapsedMicroseconds / 1000,
    scope:
        'Static transitive Dart directives from declared client roots; all conditional branches; local packages only',
  );
}

/// Hashes may differ after recompiling an edit. Added/removed dependencies or
/// changed resource ownership widen until there is a new reviewed Git baseline.
Map<String, Object?>? backendTopology(Object? graph) {
  if (graph is! Map || graph['version'] != 1 || graph['status'] != 'available') return null;
  return {
    ...graph.cast<String, Object?>(),
    'files': {
      for (final MapEntry(:key, :value) in ((graph['files'] as Map?) ?? const {}).entries)
        key: {...(value as Map).cast<String, Object?>(), 'sha256': null},
    },
  };
}

bool stableBackendGraph(Object? current, Object? previous) {
  final a = backendTopology(current), b = backendTopology(previous);
  return a != null && b != null && jsonEqual(canonical(a), canonical(b));
}

/// Offline evidence, not a complete dynamic call graph or a test result.
Impact backendImpact(
  String project,
  String gitRoot,
  String manifestFile,
  Map<String, Object?> manifest,
  Map<String, Object?>? previous,
) {
  final clock = Stopwatch()..start();
  final graph = (manifest['backendGraph'] as Map?)?.cast<String, Object?>();
  if (!stableBackendGraph(graph, previous?['backendGraph']))
    throw const MomentsError('Backend topology changed or unavailable');
  final sourcePaths = graph!['sourcePaths'];
  if (graph['engine'] != 'mix-xref+ash-resources' ||
      sourcePaths is! List ||
      sourcePaths.isEmpty ||
      sourcePaths.length > 16 ||
      graph['project'] is! String ||
      p.isAbsolute(graph['project']! as String)) {
    throw const MomentsError('Invalid backend graph');
  }
  final root = _real(p.normalize(p.join(p.dirname(manifestFile), graph['project']! as String)));
  if (!_inside(gitRoot, root) || !declarationRoots(project).roots.any((allowed) => _inside(allowed.path, root))) {
    throw const MomentsError('Backend project outside configured source roots');
  }
  final directories = [
    for (final path in sourcePaths)
      () {
        if (path is! String ||
            path.isEmpty ||
            p.isAbsolute(path) ||
            path.split(RegExp(r'[\\/]')).any((part) => const ['..', '.', ''].contains(part))) {
          throw const MomentsError('Invalid compiler source path');
        }
        final result = p.normalize(p.join(root, path));
        if (!_inside(root, result) || _real(result) != result)
          throw const MomentsError('Compiler source path escapes project');
        return result;
      }(),
  ];
  Set<String> walkAll() {
    final inventory = <String>{};
    var entries = 0;
    void walk(String directory) {
      for (final entry in Directory(directory).listSync(followLinks: false)) {
        if (++entries > 30000) throw const MomentsError('Backend inventory exceeds bound');
        final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
        if (type == FileSystemEntityType.link) throw const MomentsError('Backend source symlink is unsupported');
        if (type == FileSystemEntityType.directory) {
          walk(entry.path);
        } else if (type == FileSystemEntityType.file && entry.path.endsWith('.ex')) {
          inventory.add(entry.path);
        }
      }
    }

    directories.forEach(walk);
    return inventory;
  }

  final inventory = walkAll();
  final files = ((graph['files'] as Map?) ?? const {}).cast<String, Object?>();
  if (files.isEmpty || files.length > 20000 || files.length != inventory.length)
    throw const MomentsError('Backend inventory changed');
  final byPortable = <String, String>{}, byGit = <String, Map<String, Object?>>{};
  for (final MapEntry(key: file, value: raw) in files.entries) {
    final entry = (raw! as Map).cast<String, Object?>();
    final source = declarationSource(project, manifestFile, {'file': file, 'sha256': entry['sha256']});
    if (source['status'] != 'current' || !inventory.remove(source['absolute']) || entry['dependencies'] is! List) {
      throw const MomentsError('Stale backend graph');
    }
    final path = p.relative(source['absolute']! as String, from: gitRoot);
    byPortable[file] = path;
    byGit[path] = {...entry, 'absolute': source['absolute']};
  }
  if (inventory.isNotEmpty) throw const MomentsError('Incomplete backend inventory');
  for (final entry in files.values) {
    if (((entry! as Map)['dependencies'] as List).any((path) => !byPortable.containsKey(path)))
      throw const MomentsError('Unknown backend dependency');
  }
  final names = (manifest['moments']! as Map).keys.cast<String>().toList()..sort();
  final roots = ((graph['roots'] as Map?) ?? const {}).cast<String, Object?>();
  if (!jsonEqual(roots.keys.toList()..sort(), names)) throw const MomentsError('Backend root inventory mismatch');
  final owners = <String, Set<String>>{};
  for (final name in names) {
    final moments = (manifest['moments']! as Map).cast<String, Object?>();
    final momentRoots = roots[name];
    final sourceFile = ((moments[name] as Map?)?['source'] as Map?)?['file'];
    if (momentRoots is! List ||
        momentRoots.isEmpty ||
        momentRoots.any((file) => !byPortable.containsKey(file)) ||
        !momentRoots.contains(sourceFile)) {
      throw const MomentsError('Moment has no compiled Ash ownership');
    }
    final visited = <String>{};
    final pending = [...momentRoots.cast<String>()];
    while (pending.isNotEmpty) {
      final file = pending.removeLast();
      if (!visited.add(file)) continue;
      final path = byPortable[file]!;
      owners.putIfAbsent(path, () => {}).add(name);
      pending.addAll((byGit[path]!['dependencies']! as List).cast<String>());
    }
  }
  // Source changes while hashing/traversing cannot authorize a narrow plan.
  for (final entry in byGit.values) {
    final absolute = entry['absolute']! as String;
    if (_real(absolute) != absolute ||
        File(absolute).lengthSync() > 2 * 1024 * 1024 ||
        hashBytes(File(absolute).readAsBytesSync()) != entry['sha256']) {
      throw const MomentsError('Backend changed while planning');
    }
  }
  final after = walkAll();
  if (after.length != byGit.length || byGit.values.any((entry) => !after.contains(entry['absolute']))) {
    throw const MomentsError('Backend inventory changed while planning');
  }
  return (
    owners: owners,
    identity: hashText(jsonEncode(graph)),
    fileCount: files.length,
    elapsedMs: clock.elapsedMicroseconds / 1000,
    scope:
        'Current compiled Elixir file dependencies plus Ash domain resources; stable topology only, excluding dynamic dispatch guarantees',
  );
}
