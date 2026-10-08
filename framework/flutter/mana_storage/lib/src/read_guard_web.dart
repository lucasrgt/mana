import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web/web.dart' as web;

import 'storage_failure.dart';

/// Matches the ciphertext namespace of flutter_secure_storage_web 2.1.1.
/// Never decrypts, logs, deletes or creates a key. The provider owns encryption.
final class StorageReadGuard {
  StorageReadGuard(WebOptions options, {String? key})
    : _storage = options.useSessionStorage
          ? web.window.sessionStorage
          : web.window.localStorage,
      _namespace = options.publicKey,
      _key = key {
    _encryptionKey = _storage.getItem(_namespace);
    final all = _entries();
    // The upstream reader generates a key if missing, even with ciphertext left.
    if (all.isNotEmpty && _encryptionKey == null) {
      throw const SecureStorageUnavailable(StorageFailureReason.missingKey);
    }
    _before = _select(all);
  }

  final web.Storage _storage;
  final String _namespace;
  final String? _key;
  late final String? _encryptionKey;
  late final Map<String, String> _before;

  Map<String, String> _entries() {
    final prefix = '$_namespace.';
    final values = <String, String>{};
    for (var index = 0; index < _storage.length; index++) {
      final key = _storage.key(index);
      if (key == null || !key.startsWith(prefix)) continue;
      final value = _storage.getItem(key);
      if (value != null) values[key.substring(prefix.length)] = value;
    }
    return values;
  }

  Map<String, String> _select(Map<String, String> entries) => _key == null
      ? entries
      : {if (entries.containsKey(_key)) _key: entries[_key]!};

  void verify(Map<String, String> values) {
    final after = _select(_entries());
    if (_storage.getItem(_namespace) != _encryptionKey ||
        after.length != _before.length ||
        _before.entries.any((entry) => after[entry.key] != entry.value)) {
      // A concurrent tab changed the snapshot. Caller may explicitly read again.
      throw const SecureStorageUnavailable(
        StorageFailureReason.changedDuringRead,
      );
    }
    if (_before.keys.any((key) => !values.containsKey(key))) {
      throw const SecureStorageUnavailable(
        StorageFailureReason.unreadableRecord,
      );
    }
  }
}
