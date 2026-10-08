import 'src/account_operation.dart';
export 'src/account_operation.dart' show AccountOperationFailure;

enum ConfirmationPhase { idle, working, pending, requested, confirmed }

/// Registration and confirmation deliberately produce no authenticated session.
/// The app supplies its generated transport and owns copy and navigation.
final class EmailConfirmation extends AccountOperation<ConfirmationPhase> {
  EmailConfirmation({
    required this.register,
    required this.request,
    required this.confirm,
  }) : super(idle: ConfirmationPhase.idle, working: ConfirmationPhase.working);
  final Future<void> Function(
    String email,
    String password,
    String confirmation,
  )
  register;
  final Future<void> Function(String email) request;
  final Future<void> Function(String token) confirm;
  Future<bool> signUp(String email, String password, String confirmation) =>
      execute(
        () => register(email, password, confirmation),
        ConfirmationPhase.pending,
      );
  Future<bool> requestLink(String email) =>
      execute(() => request(email), ConfirmationPhase.requested);
  Future<bool> confirmEmail(String token) =>
      execute(() => confirm(token), ConfirmationPhase.confirmed);
}
