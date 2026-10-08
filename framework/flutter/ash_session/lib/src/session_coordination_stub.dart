import 'package:flutter_secure_storage/flutter_secure_storage.dart';

final class SessionCoordination {
  SessionCoordination(WebOptions options, String key);
  bool get shared => false;
  Stream<void> get changes => const Stream.empty();
  Future<T> exclusive<T>(Future<T> Function() action) => action();
}
