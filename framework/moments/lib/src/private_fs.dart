import 'dart:convert';
import 'dart:io';

import 'errors.dart';

final uuidPattern = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');

/// The type of [path] itself, never of what a link points at.
FileSystemEntityType entityType(String path) => FileSystemEntity.typeSync(path, followLinks: false);

bool exists(String path) => entityType(path) != FileSystemEntityType.notFound;

String realPath(String path) => File(path).resolveSymbolicLinksSync();

/// Group and other permission bits are clear. Files under a 0700 directory
/// are unreachable for other users, so this also pins ownership.
bool private(String path) => FileStat.statSync(path).mode & 0x3f == 0;

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

