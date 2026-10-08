import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical.dart';

final class DeclarationSourceError implements Exception {
  const DeclarationSourceError(this.message);
  final String message;

  @override
  String toString() => message;
}

bool _inside(String root, String file) {
  final path = p.relative(file, from: root);
  return path.isNotEmpty && path != '.' && path != '..' && !path.startsWith('../') && !p.isAbsolute(path);
}

List<int> _boundedRead(String path, int limit) {
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file || File(path).lengthSync() > limit) {
    throw const DeclarationSourceError('Declaration source exceeds its file bound');
  }
  final bytes = File(path).readAsBytesSync();
  if (bytes.length > limit) throw const DeclarationSourceError('Declaration source exceeds its file bound');
  return bytes;
}

String _real(String path) => File(path).resolveSymbolicLinksSync();

/// Roots are app-owned configuration, never inferred from untrusted manifest
/// paths. This supports sibling backends without granting the manifest
/// arbitrary file reads.
Map<String, Object?> declarationSource(String project, String manifestFile, Object? source) {
  final file = source is Map ? source['file'] : null, sha = source is Map ? source['sha256'] : null;
  if (file is! String ||
      p.isAbsolute(file) ||
      !RegExp(r'\.exs?$').hasMatch(file) ||
      sha is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
    throw const DeclarationSourceError('Invalid declaration source identity');
  }
  final (:roots, :configDigest) = declarationRoots(project);
  final absolute = _real(p.normalize(p.join(p.dirname(manifestFile), file)));
  final root = roots.where((root) => _inside(root.path, absolute)).firstOrNull;
  if (root == null) {
    throw const DeclarationSourceError(
      'Declaration source is outside configured roots; declare a sibling backend in moments/sources.json',
    );
  }
  final local = p.relative(absolute, from: root.path);
  final current = hashBytes(_boundedRead(absolute, 2 * 1024 * 1024));
  return {
    'absolute': absolute,
    'file': root.name == 'app' ? local : '${root.name}:$local',
    'sha256': current,
    'configDigest': configDigest,
    'status': current == sha ? 'current' : 'stale',
  };
}

typedef DeclarationRoots = ({List<({String name, String path})> roots, String? configDigest});

DeclarationRoots declarationRoots(String project) {
  final config = p.join(project, 'moments/sources.json');
  String? configDigest;
  var configured = <({String name, String path})>[];
  if (File(config).existsSync()) {
    final contents = _boundedRead(config, 16384);
    configDigest = hashBytes(contents);
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(contents));
    } on FormatException {
      throw const DeclarationSourceError('Invalid moments/sources.json');
    }
    if (value is! Map || value['version'] != 1 || value['roots'] is! List || (value['roots'] as List).length > 16) {
      throw const DeclarationSourceError('Invalid declaration source roots');
    }
    final names = {'app'};
    configured = [
      for (final root in value['roots'] as List)
        () {
          final name = root is Map ? root['name'] : null, path = root is Map ? root['path'] : null;
          if (name is! String ||
              !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name) ||
              names.contains(name) ||
              path is! String ||
              path.isEmpty ||
              p.isAbsolute(path)) {
            throw const DeclarationSourceError('Invalid declaration source root');
          }
          names.add(name);
          final real = Directory(p.normalize(p.join(project, path))).resolveSymbolicLinksSync();
          if (!Directory(real).existsSync()) {
            throw const DeclarationSourceError('Declaration source root is not a directory');
          }
          return (name: name, path: real);
        }(),
    ];
  }
  return (
    roots: [(name: 'app', path: Directory(project).resolveSymbolicLinksSync()), ...configured],
    configDigest: configDigest,
  );
}
