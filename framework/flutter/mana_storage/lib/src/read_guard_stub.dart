import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Native providers retain their platform behavior. This is not a durability guard.
final class StorageReadGuard {
  StorageReadGuard(WebOptions options, {String? key});
  void verify(Map<String, String> values) {}
}
