import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:web/web.dart' as web;

import 'read_guard_web.dart';
import 'storage_failure.dart';

@JS('navigator.locks')
external web.LockManager? get _locks;

/// Coordinate only absent-key initialization, using the browser's own lock.
/// Cooperating tabs must use this wrapper; existing-key writes stay concurrent.
Future<void> guardedWrite(
  WebOptions options,
  Future<void> Function() write,
) async {
  final storage = options.useSessionStorage
      ? web.window.sessionStorage
      : web.window.localStorage;
  StorageReadGuard(options);
  if (storage.getItem(options.publicKey) != null) return write();

  final locks = _locks;
  if (locks == null) {
    throw const SecureStorageUnavailable(
      StorageFailureReason.initializationUnavailable,
    );
  }
  final abort = web.AbortController();
  var expired = false;
  // Bound only acquisition. Aborting an acquired lock cannot cancel a write.
  final timer = Timer(const Duration(seconds: 5), () {
    expired = true;
    abort.abort();
  });
  try {
    await locks
        .request(
          'mana.secure-storage.initialize:${options.useSessionStorage ? 'session' : 'local'}:${options.publicKey}',
          web.LockOptions(mode: 'exclusive', signal: abort.signal),
          ((JSAny? _) {
            timer.cancel();
            return (() async {
              // Another writer may have initialized the namespace while we waited.
              // The provider imports that key; it remains the owner of all crypto.
              StorageReadGuard(options);
              await write();
              return null;
            })().toJS;
          }).toJS,
        )
        .toDart;
  } catch (_) {
    if (expired) {
      throw const SecureStorageUnavailable(
        StorageFailureReason.initializationBusy,
      );
    }
    rethrow;
  } finally {
    timer.cancel();
  }
}
