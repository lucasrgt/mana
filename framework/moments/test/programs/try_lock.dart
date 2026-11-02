import 'package:moments/src/platform.dart';

/// Tries the macOS lock on the file in the arguments from another process.
Future<void> main(List<String> args) async {
  try {
    final release = await MacPlatform().lock(args.single);
    print('locked');
    await release();
  } on Object {
    print('refused');
  }
}
