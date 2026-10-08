import 'dart:async';
import 'dart:io';

import 'package:moments/src/managed.dart';

/// Registers an empty preparation for `args[0]` at `args[1]` and stays alive.
Future<void> main(List<String> args) async {
  await registerPreparation(
    project: args[0],
    directory: args[1],
    resources: {'processes': <String>[], 'containers': <String>[], 'services': <Object>[]},
  );
  stdout.writeln('owned');
  await Completer<void>().future;
}
