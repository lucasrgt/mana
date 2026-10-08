import 'dart:async';
import 'dart:io';

import 'package:moments/src/lifecycle.dart';

/// Holds the instance lock of `args.first` until killed.
Future<void> main(List<String> args) async {
  await withInstanceLock(args.first, () async {
    stdout.writeln('held');
    await Completer<void>().future;
  });
}
