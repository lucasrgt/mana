import 'dart:io';

import 'package:path/path.dart' as p;

import 'elixir.dart';
import 'toolchain.dart';

/// The first executable named [name] on [path] (`PATH` by default).
String? onPath(String name, {String? path}) {
  for (final directory in (path ?? Platform.environment['PATH'] ?? '').split(
    ':',
  )) {
    if (directory.isEmpty) continue;
    final candidate = File(p.join(directory, name));
    if (candidate.existsSync() && candidate.statSync().mode & 0x49 != 0) {
      return candidate.path;
    }
  }
  return null;
}

/// What this machine lacks for a Mana project, one line per missing tool
/// saying how to get it. [backend] (an Ash backend: Docker, or Elixir with
/// `MANA_ELIXIR=local`), [app] (Flutter) and [contracts] (the pinned contract
/// tools) select what the project has.
Future<List<String>> requirementGaps({
  bool backend = true,
  bool app = true,
  bool contracts = true,
  Map<String, String>? environment,
}) async {
  final env = environment ?? Platform.environment;
  final path = env['PATH'] ?? '';
  String? find(String name) => onPath(name, path: path);
  final gaps = [
    if (find('git') == null) 'git is not on the PATH: install git',
    if (app && find('flutter') == null)
      'flutter is not on the PATH: install the Flutter SDK',
  ];
  if (backend && localElixir(env)) {
    if (find('mix') == null) {
      gaps.add(
        'MANA_ELIXIR=local, but mix is not on the PATH: install Elixir, or '
        'unset MANA_ELIXIR to run it in the pinned Docker image',
      );
    }
  } else if (backend) {
    if (find('docker') case final docker?) {
      final info = await Process.run(
        docker,
        ['info', '--format', '{{.ServerVersion}}'],
        environment: env,
        includeParentEnvironment: false,
      );
      if (info.exitCode != 0) {
        final reason = '${info.stderr}'.trim().split('\n').first;
        gaps.add(
          'Docker cannot reach its daemon ($reason): start Docker, or give '
          'this user access to it',
        );
      }
    } else {
      gaps.add(
        'docker is not on the PATH: install Docker (Elixir runs in a pinned '
        'image), or set MANA_ELIXIR=local where Elixir is installed',
      );
    }
  }
  return [...gaps, if (contracts) ...contractToolGaps()];
}
