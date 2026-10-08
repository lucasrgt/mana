import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'failure.dart';
import 'toolchain.dart';

final _uuid = RegExp(
  r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
);

/// Labels that let a Moments run find and clean the containers its services
/// start; values carry identity, never secrets.
List<String> momentDockerLabels([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final owner = env['MANA_RESOURCE_OWNER'],
      run = env['MANA_RESOURCE_RUN'],
      workspace = env['MANA_RESOURCE_WORKSPACE'];
  if (owner == null && run == null && workspace == null) return const [];
  if (!_uuid.hasMatch(owner ?? '') ||
      !_uuid.hasMatch(run ?? '') ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(workspace ?? '')) {
    throw const ManaFailure('Invalid Moments resource ownership');
  }
  return [
    '--label',
    'dev.moments.owner=$owner',
    '--label',
    'dev.moments.run=$run',
    '--label',
    'dev.moments.workspace=$workspace',
    '--label',
    'dev.moments.role=service',
  ];
}

/// The workspace the vendored framework lives in (its parent directory).
String workspaceRoot() => p.dirname(frameworkRoot());

String elixirImage() {
  final dockerfile = File(p.join(frameworkRoot(), 'ash/toolchain/Dockerfile'));
  return 'moments-elixir:${sha256.convert(dockerfile.readAsBytesSync()).toString().substring(0, 16)}';
}

Future<String> ensureElixirImage() async {
  final image = elixirImage();
  if (Process.runSync('docker', ['image', 'inspect', image]).exitCode == 0) {
    return image;
  }
  final build = await Process.start('docker', [
    'build',
    '-t',
    image,
    p.join(frameworkRoot(), 'ash/toolchain'),
  ], mode: ProcessStartMode.inheritStdio);
  if (await build.exitCode != 0) {
    throw const ManaFailure('Elixir toolchain build failed');
  }
  return image;
}

/// Runs `mix` in the pinned Elixir image with [project] (inside the
/// workspace) as the working directory. Only the names in [environment] are
/// passed into the container, with the values given here.
Future<void> mix(
  String project,
  List<String> args, {
  Map<String, String> environment = const {},
  bool hostNetwork = false,
}) async {
  final root = workspaceRoot();
  final path = p.relative(p.absolute(project), from: root);
  if (path.startsWith('..') || p.isAbsolute(path)) {
    throw const ManaFailure(
      'Mix project must be inside the vendored workspace',
    );
  }
  Directory(
    p.join(root, 'framework/ash/.toolchain/home'),
  ).createSync(recursive: true);
  final image = await ensureElixirImage();
  final uid = (Process.runSync('id', ['-u']).stdout as String).trim();
  final gid = (Process.runSync('id', ['-g']).stdout as String).trim();
  final child = await Process.start(
    'docker',
    [
      'run',
      '--rm',
      '--init',
      ...momentDockerLabels(),
      if (hostNetwork) '--network=host',
      '--user',
      '$uid:$gid',
      '-v',
      '$root:/workspace',
      '-v',
      '/etc/ssl/certs/ca-certificates.crt:/etc/ssl/certs/ca-certificates.crt:ro',
      '-w',
      '/workspace/$path',
      '-e',
      'HOME=/workspace/framework/ash/.toolchain/home',
      '-e',
      'MIX_HOME=/workspace/framework/ash/.toolchain/home/.mix',
      '-e',
      'HEX_HOME=/workspace/framework/ash/.toolchain/home/.hex',
      '-e',
      'HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt',
      '-e',
      'ERL_FLAGS=+S 4:4',
      for (final key in environment.keys) ...['-e', key],
      image,
      'sh',
      '-c',
      // A fresh checkout has its own empty Mix home: install Hex and rebar
      // there first, quietly, when they are missing.
      'mix local.hex --force --if-missing >/dev/null 2>&1; '
          'mix local.rebar --force --if-missing >/dev/null 2>&1; '
          'exec mix "\$@"',
      'mix',
      ...args,
    ],
    environment: environment,
    mode: ProcessStartMode.inheritStdio,
  );
  final subscriptions = [
    for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm])
      signal.watch().listen((_) => child.kill(ProcessSignal.sigterm)),
  ];
  try {
    final code = await child.exitCode;
    if (code != 0) throw ManaFailure('Mix exited $code');
  } finally {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
