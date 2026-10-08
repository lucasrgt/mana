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
  test('patch wakes a waiting client, survives restart, and rejects invalid batches atomically', () async {
    final directory = temporary('live-ui-');
    writeJson(p.join(directory, 'schema.json'), {
      'title': {'type': 'text', 'maxLength': 80},
      'gap': {
        'enum': ['md', 'xl'],
      },
    });
    writeJson(p.join(directory, 'overrides.json'), {'version': 1, 'values': <String, Object?>{}});
    var bridge = await Bridge.start(directory: directory, port: 0, momentsEnabled: false);
    try {
      expect((await send(bridge, '/state', authenticated: false)).status, 401);
      expect((await send(bridge, '/patch', data: {'title': 'Blocked'}, origin: 'https://evil.example')).status, 403);
      final initial = body(await send(bridge, '/state'));
      final waiting = send(bridge, '/changes?since=${initial['revision']}');
      final patched = body(await send(bridge, '/patch', data: {'title': 'Live title', 'gap': 'xl'}));
      expect((await waiting).body, {'revision': patched['revision'], 'values': patched['values']});
      expect((readJson(p.join(directory, 'overrides.json'))! as Map)['values'], patched['values']);
      expect((await send(bridge, '/patch', data: {'title': 'Should not persist', 'gap': 'off-scale'})).status, 400);
      expect(body(await send(bridge, '/state'))['values'], patched['values']);
      expect(
        (await send(
          bridge,
          '/ack',
          data: {'revision': patched['revision'], 'session': 'test-client', 'applyToFrameMs': 12},
        )).status,
        200,
      );
      expect((body(await send(bridge, '/state'))['acknowledgments']! as List).length, 1);
      await bridge.close();
      bridge = await Bridge.start(directory: directory, port: 0, momentsEnabled: false);
      final reopened = body(await send(bridge, '/state'));
      expect(reopened['values'], patched['values']);
      expect(reopened['revision'], isNot(patched['revision']));
      expect(body(await send(bridge, '/patch', data: {'title': null}))['values'], {'gap': 'xl'});
      expect(body(await send(bridge, '/reset', data: <String, Object?>{}))['values'], <String, Object?>{});
    } finally {
      await bridge.close();
    }
  });

  test('virtual properties persist separately and cannot leak into a normal launch', () async {
    final directory = temporary('live-ui-virtual-');
    final original = jsonEncode({
      'version': 1,
      'values': {'title': 'Original'},
    });
    writeJson(p.join(directory, 'schema.json'), {
      'title': {'type': 'text', 'maxLength': 80},
    });
    File(p.join(directory, 'overrides.json')).writeAsStringSync(original);
    final overridesFile = p.join(directory, 'virtual-overrides.json');
    File(overridesFile).writeAsStringSync(original);
    const key = 'virtual.slot_1234567890abcdef';
    var bridge = await Bridge.start(
      directory: directory,
      port: 0,
      momentsEnabled: false,
      overridesFile: overridesFile,
      extraSchema: {
        key: {
          'enum': ['xs', 'lg'],
        },
      },
    );
    addTearDown(() => bridge.close());
    expect((await send(bridge, '/patch', data: {key: 'lg'})).status, 200);
    expect(File(p.join(directory, 'overrides.json')).readAsStringSync(), original);
    expect(((readJson(overridesFile)! as Map)['values'] as Map)[key], 'lg');
    await bridge.close();
    bridge = await Bridge.start(directory: directory, port: 0, momentsEnabled: false);
    final normal = body(await send(bridge, '/state'));
    expect(normal['values'], {'title': 'Original'});
    expect((normal['schema']! as Map).containsKey(key), isFalse);
  });

  test('supervisor stop requires authentication and explicit preservation before signaling its owner', () async {
    final directory = temporary('live-ui-stop-');
    File(p.join(directory, 'schema.json')).writeAsStringSync('{}');
    writeJson(p.join(directory, 'overrides.json'), {'version': 1, 'values': <String, Object?>{}});
    final stopping = Completer<void>();
    final bridge = await Bridge.start(
      directory: directory,
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

  test('Dart-only consumer needs no archived visual editing files', () async {
    final directory = p.join(temporary('mana-plain-'), 'live-ui');
    final bridge = await Bridge.start(directory: directory, port: 0, momentsEnabled: false);
    addTearDown(bridge.close);
    expect(body(await send(bridge, '/state'))['values'], <String, Object?>{});
    final defines = (readJson(bridge.definesFile)! as Map).cast<String, Object?>();
    expect(defines['MANA_MOMENTS'], 'true');
    expect(defines.keys.any((key) => key.startsWith('MANA_LIVE_UI')), isFalse);
    expect((await send(bridge, '/patch', data: {'unknown': 'value'})).status, 400);
  });
}
