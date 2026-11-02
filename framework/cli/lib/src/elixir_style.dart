import 'dart:io';

import 'package:path/path.dart' as p;

/// What keeps a Mana backend formatted and linted, as `mana doctor` checks
/// it: `mix format` configured, Credo a dependency with the default checks
/// strict, Mana's own checks loaded (the ManaLint plugin), none of them
/// switched off, and no finding silenced in the code. Running them is the sensors' job; this says they can run as the
/// framework means them to.
List<String> elixirStyleGaps(String backend) {
  final gaps = <String>[];
  final name = p.basename(backend);
  if (!File(p.join(backend, '.formatter.exs')).existsSync()) {
    gaps.add('$name has no .formatter.exs');
  }
  final mix = File(p.join(backend, 'mix.exs'));
  final deps = mix.existsSync() ? mix.readAsStringSync() : '';
  if (!RegExp(r'\{:credo,').hasMatch(deps)) {
    gaps.add('$name does not depend on :credo');
  }
  if (!RegExp(r'\{:mana_lint,').hasMatch(deps)) {
    gaps.add('$name does not depend on :mana_lint');
  }
  final credo = File(p.join(backend, '.credo.exs'));
  if (!credo.existsSync()) {
    gaps.add('$name has no .credo.exs');
  } else {
    final text = credo.readAsStringSync();
    if (!RegExp(r'strict:\s*true').hasMatch(text)) {
      gaps.add('$name/.credo.exs is not strict');
    }
    if (!RegExp(r'plugins:\s*\[[^\]]*\{ManaLint,').hasMatch(text)) {
      gaps.add('$name/.credo.exs does not load ManaLint');
    }
    if (RegExp(
      r'disabled:|\{(Credo|ManaLint)\.Check\.[\w.]+,\s*false\}',
    ).hasMatch(text)) {
      gaps.add('$name/.credo.exs switches checks off');
    }
  }
  for (final folder in ['lib', 'test', 'config']) {
    final dir = Directory(p.join(backend, folder));
    if (!dir.existsSync()) continue;
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (!RegExp(r'\.exs?$').hasMatch(file.path)) continue;
      if (file.readAsStringSync().contains('credo:disable')) {
        gaps.add(
          '${p.relative(file.path, from: p.dirname(backend))} silences Credo',
        );
      }
    }
  }
  return gaps;
}
