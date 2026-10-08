import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'failure.dart';

typedef Fingerprint = ({String algorithm, String sha256, int files});

Map<String, Object?> fingerprintJson(Fingerprint value) => {
  'algorithm': value.algorithm,
  'sha256': value.sha256,
  'files': value.files,
};

/// Fingerprints the artifact actually mounted or served, independently of the
/// current checkout. Symlinks are recorded without following them.
Fingerprint artifactFingerprint(String directory) =>
    ArtifactFingerprint(directory).snapshot(fresh: true);

/// Repeated checks of an owned local artifact: the tree is enumerated every
/// time, file bytes are reused only while mode, size and timestamps hold. That
/// trusts filesystem metadata, not a hostile host; a fresh snapshot rereads
/// every byte.
final class ArtifactFingerprint {
  ArtifactFingerprint(String directory) : directory = p.absolute(directory);

  final String directory;
  final _cache = <String, ({String key, String digest})>{};

  static String _signature(FileStat stat) =>
      '${stat.type}:${stat.mode}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';

  Fingerprint snapshot({bool fresh = false}) {
    final records = StringBuffer();
    final seen = <String>{};
    var files = 0;
    void walk(String relative) {
      final folder = relative.isEmpty ? directory : p.join(directory, relative);
      final before = _signature(FileStat.statSync(folder));
      final names = [
        for (final entry in Directory(folder).listSync(followLinks: false))
          p.basename(entry.path),
      ]..sort();
      for (final name in names) {
        final path = relative.isEmpty ? name : '$relative/$name';
        final absolute = p.join(directory, path);
        switch (FileSystemEntity.typeSync(absolute, followLinks: false)) {
          case FileSystemEntityType.directory:
            records.write(
              '${jsonEncode(['directory', path, FileStat.statSync(absolute).mode & 0x1ff])}\n',
            );
            walk(path);
          case FileSystemEntityType.link:
            records.write(
              '${jsonEncode(['link', path, Link(absolute).targetSync()])}\n',
            );
            files++;
          case FileSystemEntityType.file:
            final stat = FileStat.statSync(absolute),
                key = _signature(stat),
                previous = _cache[path];
            final digest = !fresh && previous?.key == key
                ? previous!.digest
                : sha256.convert(File(absolute).readAsBytesSync()).toString();
            if (_signature(FileStat.statSync(absolute)) != key) {
              throw const ManaFailure('Artifact changed during fingerprint');
            }
            _cache[path] = (key: key, digest: digest);
            seen.add(path);
            records.write(
              '${jsonEncode(['file', path, stat.mode & 0x1ff, digest])}\n',
            );
            files++;
          default:
            throw const ManaFailure('Unsupported release artifact entry');
        }
      }
      if (_signature(FileStat.statSync(folder)) != before) {
        throw const ManaFailure('Artifact tree changed during fingerprint');
      }
    }

    try {
      walk('');
    } catch (_) {
      _cache.clear();
      rethrow;
    }
    _cache.removeWhere((key, _) => !seen.contains(key));
    return (
      algorithm: 'sha256-tree-v1',
      sha256: sha256.convert(utf8.encode(records.toString())).toString(),
      files: files,
    );
  }
}
