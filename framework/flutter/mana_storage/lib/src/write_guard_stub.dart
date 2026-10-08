import 'package:flutter_secure_storage/flutter_secure_storage.dart';

Future<void> guardedWrite(WebOptions options, Future<void> Function() write) =>
    write();
