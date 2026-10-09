import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/inspect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

typedef Answer = ({int status, Object? body});

Future<Answer> send(Bridge bridge, String path, {Object? data, bool authenticated = true, String? origin}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(data == null ? 'GET' : 'POST', Uri.parse('${bridge.url}$path'));
    request.headers.set('Content-Type', 'application/json');
    if (authenticated) request.headers.set('Authorization', 'Bearer ${bridge.token}');
    if (origin != null) request.headers.set('Origin', origin);
    if (data != null) request.add(utf8.encode(jsonEncode(data)));
    final response = await request.close().timeout(const Duration(seconds: 25));
    final text = await utf8.decoder.bind(response).join();
    return (status: response.statusCode, body: text.isEmpty ? null : jsonDecode(text));
  } finally {
    client.close(force: true);
  }
}

Map<String, Object?> body(Answer answer) => (answer.body! as Map).cast();

final class Stop implements Development {
  Stop(this.onStop);
  final void Function() onStop;
  @override
  Map<String, Object?> status() => const {};
  @override
  Future<Map<String, Object?>> Function()? get inspect => null;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => null;
  @override
  Future<void> Function()? get stop =>
      () async => onStop();
  @override
  Renewal? get renewal => null;
}

void main() {
  test('supervisor stop requires authentication and explicit preservation before signaling its owner', () async {
    final directory = temporary('mana-stop-');
    final stopping = Completer<void>();
    final bridge = await Bridge.start(
      project: directory,
      port: 0,
      momentsEnabled: false,
      development: Stop(() {
        if (!stopping.isCompleted) stopping.complete();
      }),
    );
    addTearDown(bridge.close);
    expect((await send(bridge, '/dev/stop', data: {'preserve': true}, authenticated: false)).status, 401);
    expect((await send(bridge, '/dev/stop', data: {'preserve': true}, origin: 'https://other.example')).status, 403);
    expect((await send(bridge, '/dev/stop', data: {'preserve': false})).status, 400);
    expect(stopping.isCompleted, isFalse);
    final response = await send(bridge, '/dev/stop', data: {'preserve': true});
    expect(response.status, 202);
    expect(response.body, {'status': 'stopping', 'preserved': true});
    await stopping.future.timeout(const Duration(seconds: 5));
  });

  test('a plain project gets an authenticated loopback bridge and no presentation editor', () async {
    final project = temporary('mana-plain-');
    final bridge = await Bridge.start(project: project, port: 0, momentsEnabled: false);
    addTearDown(bridge.close);
    expect((await send(bridge, '/journey/lease', authenticated: false)).status, 401);
    expect((await send(bridge, '/journey/lease', origin: 'https://evil.example')).status, 403);
    expect((await send(bridge, '/journey/lease')).status, 200);
    for (final path in ['/state', '/changes?since=x']) {
      expect((await send(bridge, path)).status, 404);
    }
    for (final path in ['/patch', '/reset', '/ack']) {
      expect((await send(bridge, path, data: <String, Object?>{})).status, 404);
    }
    expect(Directory(p.join(project, 'live-ui')).existsSync(), isFalse);
    final defines = (readJson(bridge.definesFile)! as Map).cast<String, Object?>();
    expect(defines['MANA_MOMENTS'], 'true');
    expect(defines.keys.any((key) => key.startsWith('MANA_LIVE_UI')), isFalse);
  });
}
