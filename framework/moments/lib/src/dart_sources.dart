import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'canonical.dart';
import 'errors.dart';
import 'json.dart';
import 'tree_events.dart';

bool _inside(String root, String file) {
  final path = p.relative(file, from: root);
  return path != '..' && !path.startsWith('../');
}

String _real(String path) => FileSystemEntity.isDirectorySync(path)
    ? Directory(path).resolveSymbolicLinksSync()
    : File(path).resolveSymbolicLinksSync();

typedef LocalPackage = ({String name, String root, String library, String configRoot, String lockRoot, bool app});

/// Resolved path dependencies are discovered from Pub, not an extra manual
/// list. Polling caches content hashes by file metadata; proofs force a reread.
///
/// With [events], a long-lived owner also reuses the whole snapshot until a
/// file event, an unreliable watch or [_maxAgeMs] says to rescan: a large app
/// takes tens of milliseconds to stat, on the event loop every bridge shares.
final class DartSources {
  DartSources(String project, [this.watch = const [], this.maxFiles = 20000])
    : project = Directory(project).resolveSymbolicLinksSync(),
      events = false;

  DartSources.watched(String project, this.watch)
    : project = Directory(project).resolveSymbolicLinksSync(),
      maxFiles = 20000,
      events = true;

  static const _maxAgeMs = 1000;

  final String project;
  final List<String> watch;
  final int maxFiles;
  final bool events;
  TreeEvents? _events;
  String? _eventRoots;
  Map<String, Object?>? _last;
  var _lastAt = 0.0, _changed = true;
  final _cache = <String, ({String key, String hash})>{};
  String? _graphKey;
  ({Map<String, Object?> metadata, List<LocalPackage> packages, String config})? _graph;

  String _fileHash(String file, bool fresh) {
    final stat = FileStat.statSync(file);
    if (stat.type != FileSystemEntityType.file || stat.size > 16777216) {
      throw const MomentsError('Dart source is not a bounded regular file');
    }
    final key =
        '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}:${stat.mode}';
    final previous = _cache[file];
    if (!fresh && previous?.key == key) return previous!.hash;
    final value = hashBytes(File(file).readAsBytesSync());
    if (_cache.length > maxFiles + 1024) _cache.clear();
    _cache[file] = (key: key, hash: value);
    return value;
  }

  ({Map<String, Object?> metadata, List<LocalPackage> packages, String config})? _resolved(bool fresh) {
    final pubspec = p.join(project, 'pubspec.yaml');
    if (!File(pubspec).existsSync()) return null; // Non-Pub protocol fixtures / legacy adapters.
    final configFile = p.join(project, '.dart_tool/package_config.json'), lockFile = p.join(project, 'pubspec.lock');
    if (!File(configFile).existsSync() || !File(lockFile).existsSync()) {
      throw const MomentsError('Run flutter pub get before starting Moments');
    }
    final overrides = p.join(project, 'pubspec_overrides.yaml');
    final metadata = <String, Object?>{
      'pubspec': _fileHash(pubspec, fresh),
      'lock': _fileHash(lockFile, fresh),
      'overrides': File(overrides).existsSync() ? _fileHash(overrides, fresh) : null,
    };
    final key = canonicalDigest({...metadata, 'config': _fileHash(configFile, fresh)});
    if (key != _graphKey) {
      final Map config;
      final Map lock;
      final Map app;
      try {
        config = jsonDecode(File(configFile).readAsStringSync()) as Map;
        lock = loadYaml(File(lockFile).readAsStringSync()) as Map;
        app = loadYaml(File(pubspec).readAsStringSync()) as Map;
      } on Object {
        throw const MomentsError('Cannot parse Pub manifests/resolution; run flutter pub get');
      }
      final configured = config['packages'];
      final locked = lock['packages'] as Map?;
      if (config['configVersion'] != 2 || configured is! List || locked == null || app['name'] is! String) {
        throw const MomentsError('Invalid Pub resolution');
      }
      final appName = app['name'] as String;
      final entries = {for (final entry in configured.cast<Map>()) entry['name'] as String: entry};
      if (entries.length != configured.length) throw const MomentsError('Duplicate resolved Dart package');
      final packages = <LocalPackage>[];
      final configUri = Uri.file(configFile);
      for (final MapEntry(key: name, value: entry) in entries.entries) {
        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name) ||
            entry['rootUri'] is! String ||
            entry['packageUri'] is! String) {
          throw const MomentsError('Invalid Dart package location');
        }
        final lockEntry = locked[name] as Map?;
        if (name != appName && lockEntry?['source'] != 'path') continue;
        final rootUrl = configUri.resolve(entry['rootUri'] as String);
        if (rootUrl.scheme != 'file') throw const MomentsError('Local Dart packages require file URIs');
        final configRoot = p.fromUri(rootUrl);
        final lockRoot = name == appName
            ? project
            : p.normalize(p.join(project, (lockEntry!['description'] as Map)['path'] as String));
        final root = _real(configRoot), expected = _real(lockRoot);
        if (root != expected) {
          throw const MomentsError('Resolved path differs from pubspec.lock; run flutter pub get and restart Moments');
        }
        final library = p.fromUri(Uri.directory(root).resolve(entry['packageUri'] as String));
        if (!_inside(root, library) || !_inside(root, _real(library))) {
          throw const MomentsError('Dart package library escapes its root');
        }
        packages.add((
          name: name,
          root: root,
          library: library,
          configRoot: configRoot,
          lockRoot: lockRoot,
          app: name == appName,
        ));
      }
      if (!packages.any((pkg) => pkg.app) ||
          locked.entries.any((e) => (e.value as Map)['source'] == 'path' && !entries.containsKey(e.key))) {
        throw const MomentsError('Incomplete Pub path resolution');
      }
      final normalized = [
        for (final entry in configured.cast<Map>())
          {
            'name': entry['name'],
            'packageUri': entry['packageUri'],
            'languageVersion': entry['languageVersion'],
            // JSON.stringify omitted absent values; keep the digest identical.
            'root': ?((locked[entry['name']] as Map?)?['source'] == 'path'
                ? p.relative(p.fromUri(configUri.resolve(entry['rootUri'] as String)), from: project)
                : entry['name'] == appName
                ? '.'
                : (locked[entry['name']] as Map?)?['source']),
            'version': ?(locked[entry['name']] as Map?)?['version'],
          },
      ]..sort((a, b) => (a['name']! as String).compareTo(b['name']! as String));
      _graph = (
        metadata: metadata,
        packages: packages,
        config: canonicalDigest({
          'generatorVersion': config['generatorVersion'],
          'flutterVersion': config['flutterVersion'],
          'packages': normalized,
        }),
      );
      _graphKey = key;
    }
    return _graph;
  }

  /// [reuse] false rescans now even when no event has arrived yet.
  Map<String, Object?> snapshot({bool fresh = false, bool reuse = true}) {
    if (!events) return _scan(fresh);
    final reusable = _last != null && !_changed && (_events?.reliable ?? false) && nowMs() - _lastAt < _maxAgeMs;
    if (!fresh && reuse && reusable) return {..._last!};
    _changed = false;
    final at = nowMs();
    final result = _scan(fresh);
    _follow();
    _last = result;
    _lastAt = at;
    return {...result};
  }

  void _follow() {
    final packages = _graph?.packages ?? const <LocalPackage>[];
    final trees = [for (final pkg in packages) pkg.library];
    final shallow = {
      project,
      p.join(project, '.dart_tool'),
      for (final pkg in packages) pkg.root,
      for (final path in watch) p.dirname(p.normalize(p.join(project, path))),
    };
    final key = jsonEncode([trees, shallow.toList()]);
    if (key == _eventRoots && (_events?.reliable ?? false)) return;
    unawaited(_events?.close());
    _eventRoots = key;
    _events = TreeEvents(trees, () => _changed = true, shallow: shallow);
  }

  Future<void> close() async {
    _last = null;
    await _events?.close();
  }

  Map<String, Object?> _scan(bool fresh) {
    final files = <String, String>{}, resolution = <String, Object?>{};
    final current = _resolved(fresh);
    var count = 0;
    void add(String key, String file) {
      if (++count > maxFiles) throw const MomentsError('Dart source inventory exceeds its bound');
      files[key] = _fileHash(file, fresh);
    }

    if (current != null) {
      resolution
        ..addAll(current.metadata)
        ..['config'] = current.config;
      for (final pkg in current.packages) {
        if (_real(pkg.configRoot) != pkg.root ||
            _real(pkg.lockRoot) != pkg.root ||
            !_inside(pkg.root, _real(pkg.library))) {
          throw const MomentsError('Local package root changed; run flutter pub get and restart Moments');
        }
        resolution['package:${pkg.name}/pubspec.yaml'] = _fileHash(p.join(pkg.root, 'pubspec.yaml'), fresh);
        void visit(String directory) {
          for (final entry in Directory(directory).listSync(followLinks: false)) {
            final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
            if (type == FileSystemEntityType.link) {
              throw const MomentsError('Symlinks inside Dart source libraries must be resolved explicitly');
            }
            if (type == FileSystemEntityType.directory) {
              visit(entry.path);
            } else if (entry.path.endsWith('.dart')) {
              add(
                pkg.app
                    ? p.relative(entry.path, from: project)
                    : 'package:${pkg.name}/${p.relative(entry.path, from: pkg.root)}',
                entry.path,
              );
            }
          }
        }

        visit(pkg.library);
      }
    }
    for (final path in watch) {
      final file = p.normalize(p.join(project, path));
      if (!_inside(project, file) || !path.endsWith('.dart') || !_inside(project, _real(file))) {
        throw const MomentsError('Invalid watched Dart source');
      }
      if (!files.containsKey(path)) add(path, file);
    }
    final ordered = {for (final key in files.keys.toList()..sort()) key: files[key]};
    return {
      'version': 1,
      'digest': canonicalDigest({'files': ordered, 'resolution': resolution}),
      'resolutionDigest': canonicalDigest(resolution),
      'files': ordered,
      'packageCount': current?.packages.length ?? 0,
      'fileCount': files.length,
      'scope': current != null
          ? 'App Dart libraries, resolved path-package Dart libraries, Pub manifests/lock and normalized resolution; excludes hosted/SDK source bodies, assets and native code'
          : 'Explicit watched Dart files (no Pub project)',
    };
  }

  List<({String name, String root, String library, bool app})> localPackages() => [
    for (final pkg in _resolved(true)?.packages ?? const <LocalPackage>[])
      (name: pkg.name, root: pkg.root, library: pkg.library, app: pkg.app),
  ];
}
