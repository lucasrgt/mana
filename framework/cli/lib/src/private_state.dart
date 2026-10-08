import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Creates (or truncates) [path] readable by its owner only, before any byte
/// of a private document reaches it.
RandomAccessFile openPrivate(String path) {
  final file = File(path)..writeAsBytesSync(const []);
  final chmod = Process.runSync('chmod', ['600', path]);
  if (chmod.exitCode != 0) {
    throw FileSystemException('Cannot restrict file mode', path);
  }
  return file.openSync(mode: FileMode.writeOnly);
}

/// A checkpoint is visible only as a complete document, before its side effect.
void savePrivateState(String file, Object? value) {
  final handle = openPrivate('$file.tmp');
  try {
    handle
      ..writeStringSync(
        '${const JsonEncoder.withIndent('  ').convert(value)}\n',
      )
      ..flushSync();
  } finally {
    handle.closeSync();
  }
  File('$file.tmp').renameSync(file);
  syncDirectory(p.dirname(file));
}

/// Makes a rename durable: fsync on the directory entry itself.
void syncDirectory(String directory) {
  final result = Process.runSync('sync', ['--', directory]);
  if (result.exitCode != 0) {
    throw FileSystemException('Cannot sync directory', directory);
  }
}
