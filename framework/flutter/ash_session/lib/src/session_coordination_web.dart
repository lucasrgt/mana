import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:mana_storage/mana_storage.dart';
import 'package:web/web.dart' as web;

@JS('navigator.locks')
external web.LockManager? get _locks;

/// Only session-record transitions are serialized, never HTTP or domain work.
final class SessionCoordination {
  SessionCoordination(this.options, this.key);
  final WebOptions options;
  final String key;
  bool get shared => true;
  Stream<void> get changes {
    final storage = options.useSessionStorage
        ? web.window.sessionStorage
        : web.window.localStorage;
    return web.EventStreamProviders.storageEvent
        .forTarget(web.window)
        .where(
          (event) =>
              event.storageArea == storage &&
              (event.key == null ||
                  event.key == options.publicKey ||
                  event.key == '${options.publicKey}.$key'),
        )
        .map((_) {});
  }

  Future<T> exclusive<T>(Future<T> Function() action) async {
    final locks = _locks;
    if (locks == null) {
      throw const SecureStorageUnavailable(
        StorageFailureReason.initializationUnavailable,
      );
    }
    final abort = web.AbortController();
    var expired = false;
    final timer = Timer(const Duration(seconds: 5), () {
      expired = true;
      abort.abort();
    });
    late T result;
    try {
      await locks
          .request(
            'mana.session.record:${options.useSessionStorage ? 'session' : 'local'}:${options.publicKey}:$key',
            web.LockOptions(mode: 'exclusive', signal: abort.signal),
            ((JSAny? _) {
              timer.cancel();
              return (() async {
                result = await action();
                return null;
              })().toJS;
            }).toJS,
          )
          .toDart;
      return result;
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
}
