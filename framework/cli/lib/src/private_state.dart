import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

/// libc `chmod`, `open` and `fsync` without spawning a process per write:
/// the Moments bridge saves state on every gesture, and a spawned `chmod` or
/// `sync` blocks the event loop every worker shares. Null where the symbols
/// are missing; callers then fall back to the commands.
final _libc = () {
  try {
    final libc = DynamicLibrary.process();
    return (
      malloc: libc
          .lookupFunction<
            Pointer<Uint8> Function(IntPtr),
            Pointer<Uint8> Function(int)
          >('malloc'),
      free: libc
          .lookupFunction<
            Void Function(Pointer<Uint8>),
            void Function(Pointer<Uint8>)
          >('free'),
      chmod: libc
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Uint32),
            int Function(Pointer<Uint8>, int)
          >('chmod'),
      open: libc
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Int32),
            int Function(Pointer<Uint8>, int)
          >('open'),
      fsync: libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'fsync',
      ),
      close: libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
      ),
    );
  } on Object {
    return null;
  }
}();

T? _withPath<T>(String path, T Function(Pointer<Uint8> path) use) {
  final libc = _libc;
  if (libc == null) return null;
  final bytes = utf8.encode(path);
  final native = libc.malloc(bytes.length + 1);
  if (native == nullptr) return null;
  try {
    native.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return use(native);
  } finally {
    libc.free(native);
  }
}

bool _chmod600(String path) =>
    _withPath(path, (native) => _libc!.chmod(native, 384) == 0) ?? false;

bool _fsyncDirectory(String directory) =>
    _withPath(directory, (native) {
      final fd = _libc!.open(native, 0);
      if (fd < 0) return false;
      final synced = _libc!.fsync(fd) == 0;
      _libc!.close(fd);
      return synced;
    }) ??
    false;

/// Creates (or truncates) [path] readable by its owner only, before any byte
/// of a private document reaches it.
RandomAccessFile openPrivate(String path) {
  final file = File(path)..writeAsBytesSync(const []);
  if (!_chmod600(path) &&
      Process.runSync('chmod', ['600', path]).exitCode != 0) {
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
  if (_fsyncDirectory(directory)) return;
  final result = Process.runSync('sync', ['--', directory]);
  if (result.exitCode != 0) {
    throw FileSystemException('Cannot sync directory', directory);
  }
}
