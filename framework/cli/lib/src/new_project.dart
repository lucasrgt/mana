import 'dart:io';

import 'package:path/path.dart' as p;

import 'failure.dart';
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
  for (final (label, command, args, cwd) in [
    ('contract tools', mana, ['contracts', 'install'], root),
    ('backend dependencies', mana, ['mix', 'backend', 'deps.get'], root),
    (
      'first migration',
      mana,
      ['mix', 'backend', 'ash.codegen', 'initial'],
      root,
    ),
    (
      'API contract',
      mana,
      [
        'mix',
        'backend',
        'contracts.export',
        '$module.Notes',
        '/api',
        '../contract/api.json',
        '${module}Web.OpenApi',
      ],
      root,
    ),
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

Future<void> _run(String command, List<String> args, String cwd) async {
  final process = await Process.start(
    command,
    args,
    workingDirectory: cwd,
    mode: ProcessStartMode.inheritStdio,
  );
  if (await process.exitCode != 0) {
    throw ManaFailure(
      '${p.basename(command)} ${args.join(' ')} failed in $cwd',
    );
  }
}
