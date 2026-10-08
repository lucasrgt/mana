import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mana/mana.dart' show uuidV4;
import 'package:moments/src/browser.dart';
import 'package:moments/src/preview_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));
String hex(int bytes) =>
    [for (var i = 0; i < bytes; i++) Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')].join();

Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

final class Fixture {
  Fixture._(this.directory, this.port);
  final String directory;
  final int port;
  final origins = const ['http://127.0.0.1:5316'];
  late PreviewHost host;

  static Future<Fixture> start() async {
    final f = Fixture._(temporary('mana-preview-'), await freePort());
    f.host = await PreviewHost.serve(directory: f.directory, port: f.port, origins: f.origins);
    addTearDown(() => f.host.close());
    return f;
  }

  BrowserProvider client() => browserSocketProvider(path: host.socket, id: host.provider);
  Future<void> restart() async {
    await host.close();
    host = await PreviewHost.serve(directory: directory, port: port, origins: origins);
  }

  String url() => '${origins.first}/tasks?momentsActor=${uuidV4()}';

  Future<({int status, Map<String, Object?> body})> post(
    String path,
    Map<String, Object?> body, {
    String? token,
    String? origin,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('${host.url}$path'));
      request.headers
        ..set('Origin', origin ?? host.url)
        ..set('Content-Type', 'application/json');
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      return (
        status: response.statusCode,
        body: text.isEmpty ? <String, Object?>{} : (jsonDecode(text) as Map).cast<String, Object?>(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<int> events(String document, {String? token}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('${host.url}/events?document=$document'));
      if (token != null) request.headers.set('Authorization', 'Bearer $token');
      final response = await request.close();
      final status = response.statusCode;
      client.close(force: true);
      return status;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> waiting() async {
    for (var i = 0; i < 100; i++) {
      final client = HttpClient();
      try {
        final response = await (await client.getUrl(Uri.parse('${host.url}/health'))).close();
        if ((jsonDecode(await utf8.decoder.bind(response).join()) as Map)['status'] == 'waiting') return;
      } finally {
        client.close(force: true);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw StateError('Frontend did not disconnect');
  }
}

/// A protocol peer for the preview page, not a simulated Flutter journey.
final class Frontend {
  Frontend._(this.f, this.document, this.frames, this.browserKey, this.token, this._client);
  final Fixture f;
  final String document, browserKey, token;
  final Map<String, String> frames;
  final HttpClient _client;
  final commands = <String>[];
  late final Future<void> _loop;

  static Future<Frontend> connect(
    Fixture f, {
    String? document,
    Map<String, String>? frames,
    String? browserKey,
  }) async {
    document ??= uuidV4();
    browserKey ??= hex(32);
    final joined = await f.post('/join', {
      'document': document,
      'protocol': 2,
      'ownership': {'kind': 'web-lock-v1', 'browserKey': browserKey},
    });
    expect(joined.status, 200);
    final client = HttpClient();
    final request = await client.getUrl(Uri.parse('${f.host.url}/events?document=$document'));
    request.headers.set('Authorization', 'Bearer ${joined.body['token']}');
    final response = await request.close();
    expect(response.statusCode, 200);
    final ui = Frontend._(f, document, frames ?? {}, browserKey, joined.body['token']! as String, client);
    ui._loop = () async {
      try {
        await for (final line in response.transform(utf8.decoder).transform(const LineSplitter())) {
          final value = (jsonDecode(line) as Map).cast<String, Object?>();
          if (value['type'] != null) continue;
          final method = value['method']! as String, target = (value['target']! as Map).cast<String, Object?>();
          final id = target['id']! as String;
          ui.commands.add(method);
          if (method == 'open') ui.frames[id] = target['url']! as String;
          if (method == 'close') ui.frames.remove(id);
          final current = ui.frames.containsKey(id)
              ? {'id': id, 'status': 'present', 'url': ui.frames[id]}
              : {'id': id, 'status': 'absent'};
          final result = method == 'find'
              ? {
                  'matches': ui.frames.containsKey(id) ? [current] : <Object?>[],
                  'settled': true,
                }
              : current;
          final reply = await f.post('/reply', {
            'document': document,
            'id': value['id'],
            'result': result,
          }, token: ui.token);
          expect(reply.status, 200);
        }
      } on HttpException {
        // The test closed the stream.
      } on SocketException {
        // The test closed the stream.
      }
    }();
    return ui;
  }

  Future<({int status, Map<String, Object?> body})> post(String path, Map<String, Object?> body) =>
      f.post(path, body, token: token);

  Future<void> stop() async {
    _client.close(force: true);
    await _loop;
  }
}

void main() {
  test('opening before connection is settled without preventing a later document', () async {
    final f = await Fixture.start(), client = f.client(), url = f.url();
    await expectLater(client.open!(url), throwing('refused'));
    expect((await client.resolve!(url))['unopened'], true);
    final ui = await Frontend.connect(f);
    try {
      final opened = await client.open!(f.url());
      expect(opened['status'], 'present');
      await client.close!(opened['id']! as String);
      expect(ui.frames, isEmpty);
    } finally {
      await ui.stop();
    }
  });

  test('same document reconnects across host restart; an unpaired browser cannot claim live previews', () async {
    final f = await Fixture.start();
    var ui = await Frontend.connect(f);
    final opened = await f.client().open!(f.url());
    final id = opened['id']! as String;
    expect(ui.frames.length, 1);
    final (:document, :frames, :browserKey) = (document: ui.document, frames: ui.frames, browserKey: ui.browserKey);
    await ui.stop();
    await f.waiting();
    expect((await f.post('/join', {'document': uuidV4()})).status, 409);
    await expectLater(f.client().close!(id), throwing('refused'));
    expect(frames.length, 1);
    final identity = f.host.provider;
    await f.restart();
    expect(f.host.provider, identity);
    ui = await Frontend.connect(f, document: document, frames: frames, browserKey: browserKey);
    try {
      expect((await f.client().inspect!(id))['status'], 'present');
      await f.client().close!(id);
      expect(frames, isEmpty);
      await f.client().close!(id);
      expect(ui.commands.where((x) => x == 'open'), isEmpty);
    } finally {
      await ui.stop();
    }
  });

  test('untrusted origin, missing auth, unowned surface and host-as-actor are rejected', () async {
    final f = await Fixture.start();
    final ui = await Frontend.connect(f);
    try {
      expect((await f.post('/join', {}, origin: 'https://other.invalid')).status, 403);
      expect(await f.events(ui.document), 403);
      await expectLater(f.client().open!('http://127.0.0.1:5317/tasks?momentsActor=${uuidV4()}'), throwing('refused'));
      await expectLater(f.client().close!(uuidV4()), throwing('refused'));
      expect(ui.commands, isEmpty);
      await expectLater(
        PreviewHost.serve(directory: f.directory, port: f.port, origins: [f.host.url]),
        throwing('distinct'),
      );
    } finally {
      await ui.stop();
    }
  });

  test('paired document replacement retires old previews without replaying an open', () async {
    final f = await Fixture.start();
    var ui = await Frontend.connect(f);
    final (:browserKey, :token, :document) = (browserKey: ui.browserKey, token: ui.token, document: ui.document);
    final opened = await f.client().open!(f.url());
    final id = opened['id']! as String;
    await ui.stop();
    await f.waiting();
    // Only the protocol handoff is tested here; browser-enforced exclusion and
    // actual iframe disposal are verified with the real page separately.
    final wrong = await ui.post('/join', {
      'document': uuidV4(),
      'protocol': 2,
      'ownership': {'kind': 'web-lock-v1', 'browserKey': hex(32)},
    });
    expect(wrong.status, 409);
    ui = await Frontend.connect(f, browserKey: browserKey);
    try {
      expect((await f.client().inspect!(id))['status'], 'absent');
      await f.client().close!(id);
      expect(ui.commands, isEmpty);
      expect(await f.events(document, token: token), 403);
      final current = await f.client().open!(f.url());
      expect(current['status'], 'present');
      await f.client().close!(current['id']! as String);
    } finally {
      await ui.stop();
    }
  });

  test('upgrade refuses legacy live surfaces instead of inventing a Web Lock witness', () async {
    final f = await Fixture.start(), ui = await Frontend.connect(f);
    final opened = await f.client().open!(f.url());
    await ui.stop();
    await f.waiting();
    final file = p.join(f.directory, 'frontend.json');
    final state = (readJson(file)! as Map).cast<String, Object?>()
      ..['version'] = 1
      ..remove('browser');
    File(file).writeAsStringSync(jsonEncode(state));
    Process.runSync('chmod', ['600', file]);
    await expectLater(f.restart(), throwing('Close legacy previews'));
    expect((((readJson(file)! as Map)['frames'] as Map)[opened['id']] as Map)['phase'], 'present');
  });
}
