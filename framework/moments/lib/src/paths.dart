import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// `framework/moments`: where the protocol specification and preview assets
/// live, found from this program or, when it runs from source, from the
/// resolved `package:moments` (`MANA_MOMENTS_ROOT` for a binary compiled
/// elsewhere).
String momentsRoot() {
  if (Platform.environment['MANA_MOMENTS_ROOT'] case final root? when root.isNotEmpty) return root;
  bool holds(String dir) => File(p.join(dir, 'protocol-v0.1.md')).existsSync();
  String? search(String start) {
    for (var directory = start; ;) {
      for (final candidate in [directory, p.join(directory, 'framework/moments')]) {
        if (holds(candidate)) return candidate;
      }
      final parent = p.dirname(directory);
      if (parent == directory) return null;
      directory = parent;
    }
  }

  final library = Isolate.resolvePackageUriSync(Uri.parse('package:moments/moments.dart'));
  final found =
      search(p.dirname(p.fromUri(Platform.script))) ?? (library == null ? null : search(p.dirname(p.fromUri(library))));
  return found ?? (throw StateError('Cannot locate framework/moments next to this program'));
}
