import 'dart:async';

import 'package:dio/dio.dart';
import 'package:signals_core/signals_core.dart';

enum AccountOperationFailure { rejected, unavailable, throttled, uncertain }

/// Safe admission and outcomes for account writes. Never retains request data,
/// raw transport errors or credentials, and never automatically retries a write.
class AccountOperation<T> {
  AccountOperation({required this.idle, required this.working})
    : phase = signal(idle);
  final T idle;
  final T working;
  final Signal<T> phase;
  final failure = signal<AccountOperationFailure?>(null);
  final throttled = signal(false);
  bool _disposed = false;
  Timer? _cooldown;
  Future<bool> execute(Future<void> Function() action, T success) async {
    if (_disposed || phase.peek() == working || throttled.peek()) return false;
    phase.value = working;
    failure.value = null;
    try {
      await action();
      if (_disposed) return false;
      phase.value = success;
      return true;
    } on DioException catch (error) {
      if (_disposed) return false;
      final status = error.response?.statusCode;
      if (status == 429) {
        final values = error.response?.headers['retry-after'];
        final seconds =
            (values?.length == 1 ? int.tryParse(values!.single) : null) ?? 60;
        throttled.value = true;
        _cooldown = Timer(Duration(seconds: seconds.clamp(1, 3600)), () {
          if (!_disposed) throttled.value = false;
        });
        failure.value = AccountOperationFailure.throttled;
      } else {
        failure.value = status == 422
            ? AccountOperationFailure.rejected
            : status == 503
            ? AccountOperationFailure.unavailable
            : AccountOperationFailure.uncertain;
      }
    } on Object {
      if (_disposed) return false;
      failure.value = AccountOperationFailure.uncertain;
    }
    phase.value = idle;
    return false;
  }

  void dispose() {
    _disposed = true;
    _cooldown?.cancel();
    phase.dispose();
    failure.dispose();
    throttled.dispose();
  }
}
