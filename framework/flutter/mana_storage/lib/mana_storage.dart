import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'src/read_guard_stub.dart'
    if (dart.library.js_interop) 'src/read_guard_web.dart';
import 'src/write_guard_stub.dart'
    if (dart.library.js_interop) 'src/write_guard_web.dart';

export 'src/storage_failure.dart';

/// Uses the existing provider and format; makes unreadable web entries explicit.
/// No retries, fallback encryption, automatic deletion or process queue.
final class ManaSecureStorage {
  const ManaSecureStorage({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;

  Future<String?> read({required String key}) async {
    final guard = StorageReadGuard(_storage.webOptions, key: key);
    final value = await _storage.read(key: key);
    guard.verify({if (value != null) key: value});
    return value;
  }

  Future<Map<String, String>> readAll() async {
    final guard = StorageReadGuard(_storage.webOptions);
    final values = await _storage.readAll();
    guard.verify(values);
    return values;
  }

  Future<void> write({required String key, required String value}) =>
      guardedWrite(
        _storage.webOptions,
        () => _storage.write(key: key, value: value),
      );

  Future<void> delete({required String key}) => _storage.delete(key: key);
}
