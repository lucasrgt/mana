import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show artifactFingerprint, fingerprintJson, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'lifecycle.dart';
import 'private_fs.dart';

final _key = RegExp(r'^[a-f0-9]{64}$');

void _privateDirectory(String path) {
  makePrivateDirectory(path, recursive: true);
  if (entityType(path) != FileSystemEntityType.directory || realPath(path) != path || !private(path)) {
    throw const MomentsError('Private owned artifact cache required');
  }
}

bool _contained(String root, String path) {
  final relative = p.relative(path, from: root);
  return relative != '..' && !relative.startsWith('../');
}

/// Links must stay within their artifact, including chained links: copying a
/// cached release must never turn an external runtime file into a build input.
Map<String, Object?> _sealedTree(String root) {
  if (entityType(root) != FileSystemEntityType.directory) throw const MomentsError('Artifact root must be a directory');
  void walk(String dir) {
    for (final entry in Directory(dir).listSync(followLinks: false)) {
      switch (entityType(entry.path)) {
        case FileSystemEntityType.link:
          final target = Link(entry.path).targetSync();
          if (target.startsWith('/') ||
              !_contained(root, p.normalize(p.join(p.dirname(entry.path), target))) ||
              !_contained(root, realPath(entry.path))) {
            throw const MomentsError('Artifact link escapes its tree');
          }
        case FileSystemEntityType.directory:
          walk(entry.path);
        case FileSystemEntityType.file:
          break;
        default:
          throw const MomentsError('Unsupported artifact entry');
      }
    }
  }

  walk(root);
  return fingerprintJson(artifactFingerprint(root));
}

void _copyTree(String from, String to) {
  final result = Process.runSync('cp', ['-a', '--no-dereference', '--', from, to]);
  if (result.exitCode != 0) throw const MomentsError('Artifact copy failed');
}

/// Caches build products only. Keys are caller-owned input contracts;
/// database snapshots, credentials, captures and runtime state never enter it.
final class ArtifactCache {
  ArtifactCache(String directory, {required List<String> names}) : _home = p.normalize(p.absolute(directory)) {
    _privateDirectory(_home);
    if (names.isEmpty ||
        names.toSet().length != names.length ||
        names.any((n) => !RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(n))) {
      throw const MomentsError('Declare distinct artifact names');
    }
    _ordered = [...names]..sort();
  }

  final String _home;
  late final List<String> _ordered;

  Map<String, String> _paths(Map<String, String> values) {
    if (jsonEncode(values.keys.toList()..sort()) != jsonEncode(_ordered)) {
      throw const MomentsError('Artifact set differs from cache contract');
    }
    return {for (final name in _ordered) name: p.normalize(p.absolute(values[name]!))};
  }

  String _entry(String key) {
    if (!_key.hasMatch(key)) throw const MomentsError('Invalid artifact cache key');
    return p.join(_home, key);
  }

  Map<String, Object?>? _inspect(String key) {
    final path = _entry(key);
    if (!exists(path)) return null;
    if (entityType(path) != FileSystemEntityType.directory || !private(path)) {
      throw const MomentsError('Cache entry ownership changed');
    }
    final record = readJsonObject(p.join(path, 'manifest.json'), 65536, 'Invalid cache manifest', privateOnly: true);
    final artifacts = record['artifacts'];
    if (record['version'] != 1 ||
        record['key'] != key ||
        artifacts is! Map ||
        jsonEncode(artifacts.keys.toList()..sort()) != jsonEncode(_ordered)) {
      throw const MomentsError('Invalid cache identity');
    }
    for (final name in _ordered) {
      if (jsonEncode(_sealedTree(p.join(path, name))) != jsonEncode(artifacts[name])) {
        throw const MomentsError('Cached artifact changed');
      }
    }
    return record;
  }

  void _reject(String key) {
    final path = _entry(key);
    if (!exists(path)) return;
    final rejected = p.join(_home, '.rejected');
    _privateDirectory(rejected);
    Directory(path).renameSync(p.join(rejected, '$key-${uuidV4()}'));
    syncDirectory(_home);
  }

  Future<T> _locked<T>(T Function() operation) => withInstanceLock(_home, () async => operation());

  Future<Map<String, Object?>> restore({required String key, required Map<String, String> targets}) {
    final output = _paths(targets);
    _entry(key);
    return _locked(() {
      Map<String, Object?>? record;
      try {
        record = _inspect(key);
      } on Object {
        _reject(key);
        return {'status': 'miss', 'reason': 'invalid', 'key': key};
      }
      if (record == null) return {'status': 'miss', 'reason': 'absent', 'key': key};
      for (final path in output.values) {
        if (exists(path) || _contained(_home, path) || _contained(path, _home)) {
          throw const MomentsError('Restore requires fresh destinations outside cache');
        }
      }
      final artifacts = record['artifacts']! as Map;
      for (final name in _ordered) {
        makePrivateDirectory(p.dirname(output[name]!), recursive: true);
        _copyTree(p.join(_entry(key), name), output[name]!);
        if (jsonEncode(_sealedTree(output[name]!)) != jsonEncode(artifacts[name])) {
          throw const MomentsError('Restored artifact changed during copy');
        }
      }
      return {'status': 'hit', 'key': key, 'artifacts': artifacts};
    });
  }

  Future<Map<String, Object?>> publish({required String key, required Map<String, String> artifacts}) {
    final inputs = _paths(artifacts);
    _entry(key);
    return _locked(() {
      try {
        if (_inspect(key) != null) return {'status': 'existing', 'key': key};
      } on Object {
        _reject(key);
      }
      final stage = p.join(_home, '.staging-${uuidV4()}');
      makePrivateDirectory(stage);
      try {
        final products = <String, Object?>{};
        for (final name in _ordered) {
          if (_contained(_home, inputs[name]!) || _contained(inputs[name]!, _home)) {
            throw const MomentsError('Build input must be outside cache');
          }
          products[name] = _sealedTree(inputs[name]!);
          _copyTree(inputs[name]!, p.join(stage, name));
          if (jsonEncode(_sealedTree(p.join(stage, name))) != jsonEncode(products[name])) {
            throw const MomentsError('Build output changed while publishing');
          }
        }
        savePrivateState(p.join(stage, 'manifest.json'), {'version': 1, 'key': key, 'artifacts': products});
        Directory(stage).renameSync(_entry(key));
        syncDirectory(_home);
        return {'status': 'stored', 'key': key};
      } finally {
        if (exists(stage)) Directory(stage).deleteSync(recursive: true);
      }
    });
  }
}
