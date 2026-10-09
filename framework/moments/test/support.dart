import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dart test` runs from the package root, `framework/moments`.
final package = Directory.current.path;
String? _snapshot;

/// [source] compiled to a kernel file, so a test can spawn it without
/// recompiling the package each time.
Future<String> compileProgram(String source) async {
  final dir = Directory.systemTemp.createTempSync('moments-dill-');
  final out = p.join(dir.path, '${p.basenameWithoutExtension(source)}.dill');
  final result = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    p.join(package, source),
    '-o',
    out,
  ]);
  if (result.exitCode != 0) throw StateError('Cannot compile $source: ${result.stderr}${result.stdout}');
  return out;
}

/// The CLI compiled once per test file (`setUpAll(compileCli)`): spawning it
/// from source would recompile the whole package for every invocation.
Future<void> compileCli() async => _snapshot = await compileProgram('bin/moments.dart');

String _entry() => _snapshot ?? (throw StateError('Call setUpAll(compileCli) in this test file'));

typedef Run = ({int code, String stdout, String stderr});

/// Runs the CLI as a separate program, like a person or an agent does.
Future<Run> moments(List<String> args, {required String cwd, Map<String, String>? environment}) async {
  final result = await Process.run(
    Platform.resolvedExecutable,
    [_entry(), ...args],
    workingDirectory: cwd,
    environment: {'MANA_MOMENTS_ROOT': package, ...?environment},
  ).timeout(const Duration(seconds: 60));
  return (code: result.exitCode, stdout: result.stdout as String, stderr: result.stderr as String);
}

/// A private temporary directory removed after the test.
String temporary([String prefix = 'moments-test-']) {
  final dir = Directory.systemTemp.createTempSync(prefix).resolveSymbolicLinksSync();
  Process.runSync('chmod', ['700', dir]);
  addTearDown(() {
    if (Directory(dir).existsSync()) Directory(dir).deleteSync(recursive: true);
  });
  return dir;
}

void writeJson(String file, Object? value) {
  Directory(p.dirname(file)).createSync(recursive: true);
  File(file).writeAsStringSync(jsonEncode(value));
}

Object? readJson(String file) => jsonDecode(File(file).readAsStringSync());

/// A loopback HTTP server answering with [handler]; closed after the test.
Future<HttpServer> serve(Future<void> Function(HttpRequest request) handler) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen(handler);
  addTearDown(() => server.close(force: true));
  return server;
}

Future<void> replyJson(HttpRequest request, Object? value, {int status = 200}) async {
  request.response
    ..statusCode = status
    ..headers.contentType = ContentType.json
    ..write(jsonEncode(value));
  await request.response.close();
}

/// A request against a bridge-like API with a bearer token.
Future<({int code, Map<String, Object?> value})> call(
  String base,
  String token,
  String path, [
  Map<String, Object?>? body,
]) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(body == null ? 'GET' : 'POST', Uri.parse('$base$path'));
    request.headers
      ..set('Authorization', 'Bearer $token')
      ..set('Content-Type', 'application/json');
    if (body != null) request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 10));
    final text = await utf8.decoder.bind(response).join();
    return (
      code: response.statusCode,
      value: text.isEmpty ? <String, Object?>{} : (jsonDecode(text) as Map).cast<String, Object?>(),
    );
  } finally {
    client.close(force: true);
  }
}

/// The compiled CLI, for owned processes started by tests.
List<String> get cliProgram => [Platform.resolvedExecutable, _entry()];

/// This package's CLI from source, for owned processes started by tests.
List<String> get cliWorker => [Platform.resolvedExecutable, p.join(package, 'bin/moments.dart')];

final _ports = Random.secure();

/// A port a test passes to a server it starts later. Binding port 0 and
/// closing it races other test files, whose own port-0 binds may be handed the
/// same number; drawing below the Linux ephemeral range (32768+) avoids that.
Future<int> freePort() async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final port = 20000 + _ports.nextInt(12000);
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await server.close();
      return port;
    } on SocketException {
      continue;
    }
  }
  throw StateError('No free test port');
}
