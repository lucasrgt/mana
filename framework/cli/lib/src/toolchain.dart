import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

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

Future<Uint8List> _download(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 60));
    if (response.statusCode != 200) {
      throw ManaFailure('Download failed (${response.statusCode}): $url');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 120))) {
      bytes.add(chunk);
    }
    return bytes.takeBytes();
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

Map<String, Object?> _tool(String name) =>
    (pinnedToolchain()[name]! as Map).cast<String, Object?>();

Map<String, Object?> _artifact(String name) {
  final artifact = (_tool(name)['platforms']! as Map)[_platform()];
  if (artifact == null) {
    throw ManaFailure('Contract tooling is not pinned for ${_platform()}');
  }
  return (artifact as Map).cast();
}

String _oasdiffPath() => cacheDirectory([
  'contracts',
  'oasdiff',
  _tool('oasdiff')['version']! as String,
  _platform(),
  'oasdiff',
]);

String _generatorPath() => cacheDirectory([
  'contracts',
  'openapi-generator',
  _tool('generator')['version']! as String,
  'openapi-generator-cli.jar',
]);

String _javaHome() => cacheDirectory([
  'contracts',
  'java',
  _tool('java')['version']! as String,
  _platform(),
]);

bool _oasdiffInstalled() {
  final binary = File(_oasdiffPath());
  return binary.existsSync() &&
      sha256Hex(binary.readAsBytesSync()) ==
          _artifact('oasdiff')['binarySha256'];
}

bool _generatorInstalled() {
  final jar = File(_generatorPath());
  return jar.existsSync() &&
      sha256Hex(jar.readAsBytesSync()) == _tool('generator')['sha256'];
}

bool _javaInstalled() {
  final home = Directory(_javaHome());
  return home.existsSync() &&
      treeSha256(home.path) == _artifact('java')['treeSha256'];
}

/// The digest of every entry under [root], in path order: a file's bytes and
/// whether its owner may run it, a link's target, a directory's name. Modes
/// other than the owner's execute bit depend on the umask, so they are left
/// out.
String treeSha256(String root) {
  final lines = <String>[];
  for (final entity in Directory(
    root,
  ).listSync(recursive: true, followLinks: false)) {
    final path = p.split(p.relative(entity.path, from: root)).join('/');
    lines.add(switch (entity) {
      Link() => 'l $path ${entity.targetSync()}',
      File() =>
        'f $path ${entity.statSync().mode & 0x40 == 0 ? '-' : 'x'} '
            '${sha256Hex(entity.readAsBytesSync())}',
      _ => 'd $path',
    });
  }
  lines.sort();
  return sha256Hex(utf8.encode(lines.join('\n')));
}

String oasdiffBinary() {
  if (!_oasdiffInstalled()) {
    throw const ManaFailure(
      'Pinned oasdiff is missing or changed; run mana contracts install',
    );
  }
  return _oasdiffPath();
}

String generatorJar() {
  if (!_generatorInstalled()) {
    throw const ManaFailure(
      'Pinned OpenAPI Generator is missing or changed; run mana contracts install',
    );
  }
  return _generatorPath();
}

/// The `java` of the pinned runtime that runs the OpenAPI Generator jar. A
/// `java` on the PATH is never used: generation must not depend on which
/// Java, if any, a machine happens to have.
String javaBinary() {
  if (!_javaInstalled()) {
    throw const ManaFailure(
      'Pinned Java runtime is missing or changed; run mana contracts install',
    );
  }
  return p.join(_javaHome(), _artifact('java')['java']! as String);
}

/// The pinned contract tools missing on this machine, each line saying how
/// to get it.
List<String> contractToolGaps() {
  if ((_tool('oasdiff')['platforms']! as Map)[_platform()] == null ||
      (_tool('java')['platforms']! as Map)[_platform()] == null) {
    return [
      'Contract tools are not pinned for ${_platform()}: add its official '
          'artifacts to framework/contracts/toolchain.json',
    ];
  }
  const install = 'run mana contracts install';
  return [
    if (!_oasdiffInstalled())
      'oasdiff ${_tool('oasdiff')['version']} is missing or changed: $install',
    if (!_generatorInstalled())
      'OpenAPI Generator ${_tool('generator')['version']} is missing or changed: $install',
    if (!_javaInstalled())
      'Java runtime ${_tool('java')['version']} (for OpenAPI Generator) is missing or changed: $install',
  ];
}

/// Extracts [archive] into a fresh folder next to [destination] and returns
/// it; the caller checks it before moving it into place.
Directory _extract(
  String label,
  List<int> archive,
  String destination, [
  List<String> only = const [],
]) {
  final parent = Directory(p.dirname(destination))..createSync(recursive: true);
  final stage = parent.createTempSync('.install-');
  final file = File(p.join(stage.path, 'archive.tar.gz'))
    ..writeAsBytesSync(archive);
  final tree = Directory(p.join(stage.path, 'tree'))..createSync();
  final unpack = Process.runSync('tar', [
    '-xzf',
    file.path,
    '-C',
    tree.path,
    ...only,
  ]);
  if (unpack.exitCode != 0) {
    stage.deleteSync(recursive: true);
    throw ManaFailure('Could not extract the pinned $label');
  }
  return tree;
}

Future<String> _installOasdiff() async {
  if (_oasdiffInstalled()) return _oasdiffPath();
  final artifact = _artifact('oasdiff'), binary = _oasdiffPath();
  final archive = await _download(artifact['url']! as String);
  if (sha256Hex(archive) != artifact['sha256']) {
    throw const ManaFailure('oasdiff archive checksum mismatch');
  }
  final tree = _extract('oasdiff', archive, binary, ['oasdiff']);
  try {
    final extracted = File(p.join(tree.path, 'oasdiff'));
    if (sha256Hex(extracted.readAsBytesSync()) != artifact['binarySha256']) {
      throw const ManaFailure('oasdiff binary checksum mismatch');
    }
    Process.runSync('chmod', ['700', extracted.path]);
    extracted.renameSync(binary);
  } finally {
    tree.parent.deleteSync(recursive: true);
  }
  return binary;
}

Future<String> _installGenerator() async {
  if (_generatorInstalled()) return _generatorPath();
  final generator = _tool('generator'), jar = File(_generatorPath());
  final bytes = await _download(generator['url']! as String);
  if (sha256Hex(bytes) != generator['sha256']) {
    throw const ManaFailure('OpenAPI Generator checksum mismatch');
  }
  jar.parent.createSync(recursive: true);
  final temp = File('${jar.path}.$pid.tmp')
    ..writeAsBytesSync(bytes, flush: true);
  temp.renameSync(jar.path);
  return jar.path;
}

Future<String> _installJava() async {
  final artifact = _artifact('java'), home = Directory(_javaHome());
  final java = p.join(home.path, artifact['java']! as String);
  if (_javaInstalled()) return java;
  final archive = await _download(artifact['url']! as String);
  if (sha256Hex(archive) != artifact['sha256']) {
    throw const ManaFailure('Java runtime archive checksum mismatch');
  }
  final tree = _extract('Java runtime', archive, home.path);
  try {
    if (treeSha256(tree.path) != artifact['treeSha256']) {
      throw const ManaFailure('Java runtime files differ from the pinned tree');
    }
    if (home.existsSync()) home.deleteSync(recursive: true);
    tree.renameSync(home.path);
  } finally {
    tree.parent.deleteSync(recursive: true);
  }
  return java;
}

/// Downloads the pinned oasdiff, OpenAPI Generator and the Java runtime the
/// generator runs on into ~/.cache/mana, at once, refusing any byte that
/// differs from toolchain.json.
Future<({String oasdiff, String generator, String java})>
installToolchain() async {
  final [oasdiff, generator, java] = await Future.wait([
    _installOasdiff(),
    _installGenerator(),
    _installJava(),
  ]);
  return (oasdiff: oasdiff, generator: generator, java: java);
}
