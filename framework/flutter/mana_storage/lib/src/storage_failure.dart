enum StorageFailureReason {
  missingKey,
  unreadableRecord,
  changedDuringRead,
  initializationUnavailable,
  initializationBusy,
}

/// Contains no stored values, identities, keys or native exception details.
final class SecureStorageUnavailable implements Exception {
  const SecureStorageUnavailable(this.reason);
  final StorageFailureReason reason;
  @override
  String toString() => 'Secure storage unavailable: ${reason.name}';
}
