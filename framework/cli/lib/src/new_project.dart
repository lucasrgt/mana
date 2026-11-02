import 'dart:io';

import 'package:path/path.dart' as p;

import 'elixir.dart';
import 'failure.dart';
import 'requirements.dart';
import 'toolchain.dart';

/// A new Mana project in [target]: an Ash backend (`backend/`), a Flutter
/// app (`app/`) with its generated API client (`packages/api/`), two Moments
/// that prove the app end to end, and Mana itself as a git submodule at
/// `mana/` pinned to [manaRef] of [manaUrl] (the commit of the framework
/// running this, by default).
///
/// With [setup], it also fetches dependencies, generates the first migration,
/// exports the contract, generates the client, syncs the Moments and commits
/// the result, so `moments suite --headless --project app` runs at once.
Future<void> newProject(
  String target, {
  String? manaUrl,
  String? manaRef,
  bool setup = true,
  void Function(String line)? progress,
}) async {
  final name = p.basename(p.normalize(p.absolute(target)));
  if (!RegExp(r'^[a-z][a-z0-9_]{1,40}$').hasMatch(name)) {
    throw ManaFailure(
      'The folder name is the app name: lowercase letters, digits and _, starting with a letter ($name)',
    );
  }
  final root = p.absolute(target);
  if (Directory(root).existsSync() && Directory(root).listSync().isNotEmpty) {
    throw ManaFailure('$root already exists and is not empty');
  }
  final gaps = await requirementGaps(backend: setup, contracts: false);
  if (gaps.isNotEmpty) {
    throw ManaFailure(
      'mana new needs, on this machine:\n${gaps.map((gap) => '  - $gap').join('\n')}',
    );
  }
  final module = name
      .split('_')
      .map(
        (part) => part.isEmpty ? '' : part[0].toUpperCase() + part.substring(1),
      )
      .join();
  final framework = frameworkRoot();
  final url =
      manaUrl ??
      _git(['remote', 'get-url', 'origin'], framework) ??
      'https://github.com/lucasrgt/mana.git';
  final ref = manaRef ?? _git(['rev-parse', 'HEAD'], framework);
  if (ref == null) {
    throw const ManaFailure(
      'The framework running this is not a git checkout; pass --mana-ref',
    );
  }
  void say(String line) => (progress ?? stdout.writeln)(line);

  Directory(root).createSync(recursive: true);
  await _run('git', ['init', '-q', '-b', 'main'], root);
  say('· Mana $ref from $url as a submodule at mana/');
  final local = !url.contains('://') && !url.startsWith('git@');
  await _run('git', [
    // A local checkout (testing the framework itself) is a file transport.
    if (local) ...['-c', 'protocol.file.allow=always'],
    'submodule',
    'add',
    '-q',
    url,
    'mana',
  ], root);
  await _run('git', ['checkout', '-q', ref], p.join(root, 'mana'));
  // Docker builds the backend's image while the app and the CLI are prepared.
  final image = setup && !localElixir()
      ? _settled(
          ensureElixirImage(
            framework: p.join(root, 'mana/framework'),
            quiet: true,
          ),
        )
      : Future<Object?>.value();

  say('· Flutter app at app/');
  await _run('flutter', [
    'create',
    '--project-name',
    '${name}_app',
    '--org',
    'dev.mana.$name',
    '--platforms',
    'web,linux,android,ios',
    '--no-pub',
    'app',
  ], root);
  for (final generated in ['app/lib/main.dart', 'app/test/widget_test.dart']) {
    final file = File(p.join(root, generated));
    if (file.existsSync()) file.deleteSync();
  }

  say('· project files');
  _copyTemplate(p.join(framework, 'cli/templates/new'), root, {
    '__name__': name,
    '__Name__': module,
    '__dash__': name.replaceAll('_', '-'),
  });
  if (!setup) {
    say(
      'Done, without setup: run contracts install, mix deps.get, ash.codegen, '
      'contracts.export, client generate, flutter pub get and moments sync '
      '(mana new does them unless --no-setup).',
    );
    return;
  }

  final mana = p.join(root, 'mana/framework/cli/mana');
  final moments = p.join(root, 'mana/framework/moments/moments');
  say('· Mana CLI');
  _reuseCompiledCli(framework, p.join(root, 'mana/framework'));
  await _run(mana, ['--help'], root, quiet: true);
  // Off the backend's path: its first compile is the slowest stage, and
  // neither of these needs it.
  final alongside = _settled(
    Future.wait([
      _run(mana, ['contracts', 'install'], root, quiet: true),
      _run(moments, ['--help'], root, quiet: true),
    ]),
  );
  say('· Elixir image');
  if (await image case final Object error) throw error;
  for (final (label, args) in [
    ('backend dependencies', ['deps.get']),
    ('first migration', ['ash.codegen', 'initial']),
    (
      'API contract',
      [
        'contracts.export',
        '$module.Notes',
        '/api',
        '../contract/api.json',
        '${module}Web.OpenApi',
      ],
    ),
  ]) {
    say('· $label');
    await _run(mana, ['mix', 'backend', ...args], root);
  }
  say('· contract tools and the Moments runner');
  if (await alongside case final Object error) throw error;
  for (final (label, command, args, cwd) in [
    (
      'Dart client',
      mana,
      [
        'client',
        'generate',
        '--input',
        'contract/api.json',
        '--output',
        'packages/api',
        '--name',
        '${name}_api',
      ],
      root,
    ),
    ('app dependencies', 'flutter', ['pub', 'get'], p.join(root, 'app')),
    ('Moments', moments, ['sync', '--project', 'app'], root),
  ]) {
    say('· $label');
    await _run(command, args, cwd);
  }
  await _run('git', ['add', '-A'], root);
  await _run('git', ['commit', '-q', '-m', 'Start $name with Mana'], root);
  say(
    'Done: cd $target && mana/framework/moments/moments suite --headless --project app',
  );
}

/// Gives the project's framework the executable running this when both CLIs
/// have the same sources and lock, sparing `cli/mana` its compile, the
/// slowest step before the backend's.
void _reuseCompiledCli(String framework, String project) {
  final running = File(Platform.resolvedExecutable),
      built = File(p.join(framework, 'cli/.dart_tool/mana'));
  if (!built.existsSync() ||
      built.resolveSymbolicLinksSync() != running.resolveSymbolicLinksSync()) {
    return;
  }
  String sources(String cli) => [
    for (final folder in ['bin', 'lib']) treeSha256(p.join(cli, folder)),
    sha256Hex(File(p.join(cli, 'pubspec.lock')).readAsBytesSync()),
  ].join();
  if (sources(p.join(framework, 'cli')) != sources(p.join(project, 'cli'))) {
    return;
  }
  final target = File(p.join(project, 'cli/.dart_tool/mana'))
    ..parent.createSync(recursive: true);
  running.copySync('${target.path}.$pid');
  File('${target.path}.$pid').renameSync(target.path);
}

void _copyTemplate(String from, String to, Map<String, String> tokens) {
  String fill(String text) => tokens.entries.fold(
    text,
    (text, token) => text.replaceAll(token.key, token.value),
  );
  for (final entity in Directory(from).listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = fill(p.relative(entity.path, from: from));
    final destination = File(p.join(to, relative))
      ..parent.createSync(recursive: true);
    destination.writeAsStringSync(fill(entity.readAsStringSync()));
  }
}

String? _git(List<String> args, String cwd) {
  final result = Process.runSync('git', args, workingDirectory: cwd);
  final out = (result.stdout as String).trim();
  return result.exitCode == 0 && out.isNotEmpty ? out : null;
}

/// [work]'s error, or null once it succeeded: a step started early and
/// awaited later must not fail unhandled meanwhile.
Future<Object?> _settled(Future<Object?> work) =>
    work.then((_) => null, onError: (Object error) => error);

/// Runs [command]; a [quiet] one shows its output only when it fails, so
/// steps running side by side do not interleave.
Future<void> _run(
  String command,
  List<String> args,
  String cwd, {
  bool quiet = false,
}) async {
  final ProcessResult result;
  if (quiet) {
    result = await Process.run(command, args, workingDirectory: cwd);
  } else {
    final process = await Process.start(
      command,
      args,
      workingDirectory: cwd,
      mode: ProcessStartMode.inheritStdio,
    );
    result = ProcessResult(process.pid, await process.exitCode, '', '');
  }
  if (result.exitCode != 0) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    throw ManaFailure(
      '${p.basename(command)} ${args.join(' ')} failed in $cwd',
    );
  }
}
