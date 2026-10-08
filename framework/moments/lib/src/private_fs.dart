import 'dart:convert';
import 'dart:io';

import 'errors.dart';

final uuidPattern = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');
final sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
bool isUuid(Object? value) => value is String && uuidPattern.hasMatch(value);

/// The type of [path] itself, never of what a link points at.
FileSystemEntityType entityType(String path) => FileSystemEntity.typeSync(path, followLinks: false);

bool exists(String path) => entityType(path) != FileSystemEntityType.notFound;

String realPath(String path) => File(path).resolveSymbolicLinksSync();

/// Group and other permission bits are clear. Files under a 0700 directory
/// are unreachable for other users, so this also pins ownership.
bool private(String path) => FileStat.statSync(path).mode & 0x3f == 0;

/// A real (not linked) directory at its canonical path, optionally private.
void requireDirectory(String path, String message, {bool privateOnly = false}) {
  if (entityType(path) != FileSystemEntityType.directory || realPath(path) != path || (privateOnly && !private(path))) {
    throw MomentsError(message);
  }
}

/// A regular file of at most [limit] bytes, optionally private, decoded as JSON.
Object? readJsonFile(String file, int limit, String message, {bool privateOnly = false, String? unreadable}) {
  if (entityType(file) != FileSystemEntityType.file ||
      File(file).lengthSync() > limit ||
      (privateOnly && !private(file))) {
    throw MomentsError(message);
  }
  try {
    return jsonDecode(File(file).readAsStringSync());
  } on FormatException {
    throw MomentsError(unreadable ?? message);
  }
}

Map<String, Object?> readJsonObject(String file, int limit, String message, {bool privateOnly = false}) {
  final value = readJsonFile(file, limit, message, privateOnly: privateOnly);
  if (value is! Map) throw MomentsError(message);
  return value.cast();
}

/// Creates [file] exclusively (never clobbers) with mode 0600 and fsyncs it.
void createExclusive(String file, List<int> bytes) {
  File(file).createSync(exclusive: true);
  Process.runSync('chmod', ['600', file]);
  final handle = File(file).openSync(mode: FileMode.writeOnly);
  try {
    handle
      ..writeFromSync(bytes)
      ..flushSync();
  } finally {
    handle.closeSync();
  }
}

/// `mkdir -m 700`; [recursive] creates missing parents with the same mode.
void makePrivateDirectory(String path, {bool recursive = false}) {
  if (recursive) {
    Directory(path).createSync(recursive: true);
  } else {
    if (exists(path)) throw FileSystemException('Directory exists', path);
    Directory(path).createSync();
  }
  Process.runSync('chmod', ['700', path]);
}
