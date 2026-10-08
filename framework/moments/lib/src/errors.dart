/// A Moments refusal: the declaration, runtime or recorded state does not
/// allow the operation. [status] mirrors the JS runner's result statuses.
final class MomentsError implements Exception {
  const MomentsError(this.message, {this.status = 'unavailable'});
  final String message;
  final String status;

  @override
  String toString() => message;
}
