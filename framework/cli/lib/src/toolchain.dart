import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'failure.dart';

/// The framework checkout this CLI was built from (`MANA_FRAMEWORK` for a
/// binary compiled elsewhere).
String frameworkRoot() {
  if (Platform.environment['MANA_FRAMEWORK'] case final root?
      when root.isNotEmpty) {
    return root;
  }
  // Under `dart test` the script is a generated bootstrap; the package's own
  // location still identifies the checkout.
  final library = Isolate.resolvePackageUriSync(
    Uri.parse('package:mana/mana.dart'),
  );
  for (final start in [
    if (Platform.script.isScheme('file')) p.dirname(p.fromUri(Platform.script)),
    if (library != null && library.isScheme('file'))
      p.dirname(p.fromUri(library)),
  ]) {
    var directory = start;
    while (true) {
      for (final candidate in [directory, p.join(directory, 'framework')]) {
        if (File(p.join(candidate, 'contracts/toolchain.json')).existsSync()) {
          return candidate;
        }
      }
      if (p.dirname(directory) == directory) break;
      directory = p.dirname(directory);
    }
  }
  throw const ManaFailure('Cannot locate the Mana framework next to this CLI');
}

Map<String, Object?> pinnedToolchain() =>
    (jsonDecode(
              File(
                p.join(frameworkRoot(), 'contracts/toolchain.json'),
              ).readAsStringSync(),
            )
            as Map)
        .cast();

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

String cacheDirectory(List<String> parts) =>
    p.joinAll([Platform.environment['HOME']!, '.cache', 'mana', ...parts]);

Future<List<int>> _download(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw ManaFailure('Download failed (${response.statusCode}): $url');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 120))) {
      bytes.addAll(chunk);
    }
    return bytes;
  } finally {
    client.close(force: true);
  }
}

String _platform() {
  final arch = switch (Abi.current()) {
    Abi.linuxX64 => 'linux-x64',
    Abi.linuxArm64 => 'linux-arm64',
    Abi.macosArm64 => 'darwin-arm64',
    Abi.macosX64 => 'darwin-x64',
    final other => '$other',
  };
  return arch;
}

String _oasdiffPath() {
  final oasdiff = (pinnedToolchain()['oasdiff']! as Map)
      .cast<String, Object?>();
  return cacheDirectory([
    'contracts',
    'oasdiff',
    oasdiff['version']! as String,
    _platform(),
    'oasdiff',
  ]);
}

Map<String, Object?> _oasdiffArtifact() {
  final oasdiff = (pinnedToolchain()['oasdiff']! as Map)
      .cast<String, Object?>();
  final artifact = (oasdiff['platforms']! as Map)[_platform()];
  if (artifact == null) {
    throw ManaFailure('Contract tooling is not pinned for ${_platform()}');
  }
  return (artifact as Map).cast();
}

String oasdiffBinary() {
  final artifact = _oasdiffArtifact(), binary = File(_oasdiffPath());
  if (!binary.existsSync() ||
      sha256Hex(binary.readAsBytesSync()) != artifact['binarySha256']) {
    throw const ManaFailure(
      'Pinned oasdiff is missing or changed; run mana contracts install',
    );
  }
  return binary.path;
}

String generatorJar() {
  final generator = (pinnedToolchain()['generator']! as Map)
      .cast<String, Object?>();
  final jar = File(
    cacheDirectory([
      'contracts',
      'openapi-generator',
      generator['version']! as String,
      'openapi-generator-cli.jar',
    ]),
  );
  if (!jar.existsSync() ||
      sha256Hex(jar.readAsBytesSync()) != generator['sha256']) {
    throw const ManaFailure(
      'Pinned OpenAPI Generator is missing or changed; run mana contracts install',
    );
  }
  return jar.path;
}

/// Downloads the pinned oasdiff and OpenAPI Generator into ~/.cache/mana,
/// refusing any byte that differs from toolchain.json.
Future<({String oasdiff, String generator})> installToolchain() async {
  final artifact = _oasdiffArtifact(), binary = File(_oasdiffPath());
  if (!binary.existsSync() ||
      sha256Hex(binary.readAsBytesSync()) != artifact['binarySha256']) {
    final archive = await _download(artifact['url']! as String);
    if (sha256Hex(archive) != artifact['sha256']) {
      throw const ManaFailure('oasdiff archive checksum mismatch');
    }
    binary.parent.parent.createSync(recursive: true);
    final stage = binary.parent.parent.createTempSync('.install-');
    try {
      File(p.join(stage.path, 'archive.tar.gz')).writeAsBytesSync(archive);
      final unpack = Process.runSync('tar', [
        '-xzf',
        p.join(stage.path, 'archive.tar.gz'),
        '-C',
        stage.path,
        'oasdiff',
      ]);
      if (unpack.exitCode != 0) {
        throw const ManaFailure('Could not extract pinned oasdiff');
      }
      final extracted = File(p.join(stage.path, 'oasdiff'));
      if (sha256Hex(extracted.readAsBytesSync()) != artifact['binarySha256']) {
        throw const ManaFailure('oasdiff binary checksum mismatch');
      }
      binary.parent.createSync(recursive: true);
      Process.runSync('chmod', ['700', extracted.path]);
      extracted.renameSync(binary.path);
    } finally {
      stage.deleteSync(recursive: true);
    }
  }
  final generator = (pinnedToolchain()['generator']! as Map)
      .cast<String, Object?>();
  final jar = File(
    cacheDirectory([
      'contracts',
      'openapi-generator',
      generator['version']! as String,
      'openapi-generator-cli.jar',
    ]),
  );
  if (!jar.existsSync() ||
      sha256Hex(jar.readAsBytesSync()) != generator['sha256']) {
    final bytes = await _download(generator['url']! as String);
    if (sha256Hex(bytes) != generator['sha256']) {
      throw const ManaFailure('OpenAPI Generator checksum mismatch');
    }
    jar.parent.createSync(recursive: true);
    final temp = File('${jar.path}.$pid.tmp')
      ..writeAsBytesSync(bytes, flush: true);
    temp.renameSync(jar.path);
  }
  return (oasdiff: binary.path, generator: jar.path);
}
