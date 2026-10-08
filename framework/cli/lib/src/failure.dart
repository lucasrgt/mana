/// A refusal the CLI reports as `mana: <message>` with exit code 1.
final class ManaFailure implements Exception {
  const ManaFailure(this.message);
  final String message;

  @override
  String toString() => message;
}
