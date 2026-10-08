import 'src/account_operation.dart';
export 'src/account_operation.dart' show AccountOperationFailure;

enum RecoveryPhase { idle, working, requested, reset }

typedef RecoveryFailure = AccountOperationFailure;

final class PasswordRecovery extends AccountOperation<RecoveryPhase> {
  PasswordRecovery({required this.request, required this.reset})
    : super(idle: RecoveryPhase.idle, working: RecoveryPhase.working);
  final Future<void> Function(String email) request;
  final Future<void> Function(
    String token,
    String password,
    String confirmation,
  )
  reset;
  Future<bool> requestLink(String email) =>
      execute(() => request(email), RecoveryPhase.requested);
  Future<bool> changePassword(
    String token,
    String password,
    String confirmation,
  ) => execute(() => reset(token, password, confirmation), RecoveryPhase.reset);
}
