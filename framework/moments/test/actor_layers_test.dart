import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState, uuidV4;
import 'package:moments/src/bridge.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/layers.dart';
import 'package:moments/src/web_actor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));
const actor = FlutterActorLayer();

final class ActorFixture {
  ActorFixture() : dir = temporary('mana-actor-layer-') {
    source = p.join(dir, 'source');
    Directory(source).createSync();
    savePrivateState(p.join(source, 'ui-session.json'), {
      'version': 2,
      'active': 'draft',
      'states': {
        'draft': {
          'name': 'draft',
          'projection': {'route': '/tasks', 'draftTitle': 'Original'},
        },
      },
    });
    savePrivateState(p.join(source, 'actor-state.json'), {
      'version': 1,
      'values': {'session': 'PRIVATE-SENTINEL'},
    });
    handle = FlutterActorLayer.sourceHandle(source);
  }

  final String dir;
  late final String source;
  late final LayerHandle handle;
  var live = false;
  LayerOptions get opts => LayerOptions(
    assertStopped: (_) {
      if (live) throw const MomentsError('Runtime must stop');
    },
  );
}

Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<({int status, String text, HttpHeaders headers})> get(
  String url, [
  Map<String, String> headers = const {},
]) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    final response = await request.close();
    return (status: response.statusCode, text: await utf8.decoder.bind(response).join(), headers: response.headers);
  } finally {
    client.close(force: true);
  }
}

final class Store {
  Store(this.directory, this.slots);
  final String directory;
  final List<String> slots;
  late Bridge bridge;
  Future<void> start() async {
    bridge = await Bridge.start(project: directory, port: 0, momentsEnabled: false, privateStores: slots);
    addTearDown(bridge.close);
  }

  Future<void> restart() async {
    await bridge.close();
    await start();
  }

  Future<({int status, String text})> request(
    Map<String, Object?> input, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('${bridge.url}/moments/private-store'));
      request.headers
        ..set('Authorization', 'Bearer ${bridge.token}')
        ..set('Content-Type', 'application/json');
      headers.forEach(request.headers.set);
      request.add(utf8.encode(jsonEncode(input)));
      final response = await request.close();
      return (status: response.statusCode, text: await utf8.decoder.bind(response).join());
    } finally {
      client.close(force: true);
    }
  }

  Future<Object?> body(Map<String, Object?> input) async => jsonDecode((await request(input)).text);
}

void main() {
  group('flutter actor layer', () {
    test('Flutter actor copies declared UI and private store independently and rejects changed snapshots', () async {
      final f = ActorFixture(), snapshot = p.join(f.dir, 'snapshot');
      await actor.capture(handle: f.handle, out: snapshot, opts: f.opts);
      final a = await actor.materialize(dir: p.join(f.dir, 'a'), from: snapshot);
      final b = await actor.materialize(dir: p.join(f.dir, 'b'), from: snapshot);
      final aDir = a['dir']! as String, bDir = b['dir']! as String;
      savePrivateState(p.join(aDir, 'actor-state.json'), {
        'version': 1,
        'values': {'session': ''},
      });
      final original = File(p.join(snapshot, 'ui-session.json')).readAsStringSync();
      File(p.join(aDir, 'ui-session.json')).writeAsStringSync(original.replaceFirst('Original', 'Changed'));
      expect(File(p.join(bDir, 'ui-session.json')).readAsStringSync(), original);
      expect(((readJson(p.join(bDir, 'actor-state.json'))! as Map)['values'] as Map)['session'], 'PRIVATE-SENTINEL');
      expect(FileStat.statSync(p.join(bDir, 'actor-state.json')).mode & 0x1ff, 0x180);
      File(p.join(snapshot, 'ui-session.json')).writeAsStringSync(original.replaceFirst('Original', 'Changed'));
      await expectLater(actor.materialize(dir: p.join(f.dir, 'c'), from: snapshot), throwing('changed or incomplete'));
      expect(Directory(p.join(f.dir, 'c')).existsSync(), isFalse);
      await actor.dispose(handle: a, opts: f.opts);
      await actor.dispose(handle: b, opts: f.opts);
      await actor.forget(dir: snapshot);
      expect(Directory(f.source).existsSync(), isTrue);
    });

    test('Flutter capture/disposal require a stop check, owned handle and fresh destination', () async {
      final f = ActorFixture(), snapshot = p.join(f.dir, 'snapshot');
      await expectLater(actor.capture(handle: f.handle, out: snapshot), throwing('stop check'));
      f.live = true;
      await expectLater(actor.capture(handle: f.handle, out: snapshot, opts: f.opts), throwing('Runtime must stop'));
      f.live = false;
      await actor.capture(handle: f.handle, out: snapshot, opts: f.opts);
      await expectLater(actor.capture(handle: f.handle, out: snapshot, opts: f.opts), throwing('exists'));
      final copy = await actor.materialize(dir: p.join(f.dir, 'copy'), from: snapshot);
      await expectLater(actor.dispose(handle: {...copy, 'id': 'wrong'}, opts: f.opts), throwing('ownership'));
      await expectLater(actor.dispose(handle: f.handle, opts: f.opts), throwing('handle'));
      f.live = true;
      await expectLater(actor.dispose(handle: copy, opts: f.opts), throwing('Runtime must stop'));
      f.live = false;
      await actor.dispose(handle: copy, opts: f.opts);
      await actor.forget(dir: snapshot);
    });

    test('actor layer refuses symlink checkpoint files', () {
      final f = ActorFixture();
      File(p.join(f.source, 'actor-state.json')).deleteSync();
      Link(p.join(f.source, 'actor-state.json')).createSync(p.join(f.source, 'ui-session.json'));
      expect(() => FlutterActorLayer.sourceHandle(f.source), throwing('checkpoint file'));
    });

    test('recovery removes only a dead creator owned copy after the runtime stop check', () async {
      final f = ActorFixture(), snapshot = p.join(f.dir, 'snapshot');
      await actor.capture(handle: f.handle, out: snapshot, opts: f.opts);
      final copy = await actor.materialize(dir: p.join(f.dir, 'copy'), from: snapshot);
      final dir = copy['dir']! as String, file = p.join(dir, 'actor-layer.json');
      await expectLater(actor.recover(dir: dir, opts: f.opts), throwing('creator is alive'));
      final record = (readJson(file)! as Map).cast<String, Object?>();
      (record['supervisor']! as Map)['pid'] = 2147483647;
      savePrivateState(file, record);
      f.live = true;
      await expectLater(actor.recover(dir: dir, opts: f.opts), throwing('Runtime must stop'));
      f.live = false;
      File(p.join(dir, 'unexpected.txt')).writeAsStringSync('retain me');
      await expectLater(actor.recover(dir: dir, opts: f.opts), throwing('Unexpected files'));
      expect(File(p.join(dir, 'actor-state.json')).existsSync(), isTrue);
      File(p.join(dir, 'unexpected.txt')).deleteSync();
      File(p.join(dir, '.runtime.json')).writeAsStringSync('{}');
      File(p.join(dir, '.defines.json')).writeAsStringSync('{}');
      await actor.recover(dir: dir, opts: f.opts);
      await actor.recover(dir: dir, opts: f.opts);
      expect((readJson(file)! as Map)['phase'], 'disposed');
      expect(File(p.join(dir, 'actor-state.json')).existsSync(), isFalse);
      expect(File(p.join(f.source, 'actor-state.json')).existsSync(), isTrue);
      expect(File(p.join(snapshot, 'actor-state.json')).existsSync(), isTrue);
    });

    test('a failed copy can be cleaned by its own coordinator, without authorizing live ready copies', () async {
      final f = ActorFixture(), snapshot = p.join(f.dir, 'partial');
      final target = p.join(snapshot, 'actor-state.json');
      await IOOverrides.runZoned(
        () async => expectLater(
          actor.capture(handle: f.handle, out: snapshot, opts: f.opts),
          throwsA(isA<FileSystemException>()),
        ),
        createFile: (path) =>
            path == target ? _RealFile('/proc/self/no-such-directory/actor-state.json') : _RealFile(path),
      );
      expect((readJson(p.join(snapshot, 'actor-layer.json'))! as Map)['phase'], 'attention');
      expect(File(p.join(snapshot, 'ui-session.json')).existsSync(), isTrue);
      await actor.recover(dir: snapshot, opts: f.opts, pending: true);
      await actor.recover(dir: snapshot, opts: f.opts, pending: true);
      expect(File(target).existsSync(), isFalse);
      expect(File(p.join(f.source, 'actor-state.json')).existsSync(), isTrue);
    });
  });

  group('private store', () {
    const first = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        second = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const secret = 'PRIVATE-SESSION-SENTINEL';

    Future<Store> store([List<String> slots = const ['session']]) async {
      final s = Store(temporary('mana-private-actor-'), slots);
      await s.start();
      return s;
    }

    test('private session survives bridge restart without entering public projections', () async {
      final f = await store();
      expect((await f.request({'operation': 'claim', 'client': first})).status, 200);
      expect(await f.body({'operation': 'read', 'client': first, 'key': 'session'}), {'value': null});
      expect(await f.body({'operation': 'write', 'client': first, 'key': 'session', 'value': secret}), {'saved': true});
      expect(FileStat.statSync(p.join(f.directory, 'actor-state.json')).mode & 0x1ff, 0x180);
      await f.restart();
      expect((await f.request({'operation': 'read', 'client': first, 'key': 'session'})).status, 409);
      await f.request({'operation': 'claim', 'client': second});
      expect(await f.body({'operation': 'read', 'client': second, 'key': 'session'}), {'value': secret});
    });

    test('private store rejects unauthorized origins, stale clients, undeclared slots and malformed writes', () async {
      final f = await store();
      expect(
        (await f.request({'operation': 'claim', 'client': first}, headers: {'Authorization': 'Bearer wrong'})).status,
        401,
      );
      expect(
        (await f.request(
          {'operation': 'claim', 'client': first},
          headers: {'Origin': 'https://outside.example'},
        )).status,
        403,
      );
      await f.request({'operation': 'claim', 'client': first});
      await f.request({'operation': 'write', 'client': first, 'key': 'session', 'value': secret});
      await f.request({'operation': 'claim', 'client': second});
      expect((await f.request({'operation': 'write', 'client': first, 'key': 'session', 'value': ''})).status, 409);
      for (final data in <Map<String, Object?>>[
        {'key': 'other', 'value': ''},
        {'key': 'session', 'value': null},
        {'key': 'session', 'value': 'x' * 8193},
      ]) {
        final response = await f.request({'operation': 'write', 'client': second, ...data});
        expect(response.status, 400);
        expect(response.text.contains(secret), isFalse);
      }
      expect(((readJson(p.join(f.directory, 'actor-state.json'))! as Map)['values'] as Map)['session'], secret);
      // Logout and rejection sentinels remain distinct from an absent slot.
      for (final value in ['', '!rejected']) {
        await f.request({'operation': 'write', 'client': second, 'key': 'session', 'value': value});
        expect(await f.body({'operation': 'read', 'client': second, 'key': 'session'}), {'value': value});
      }
    });

    test('bridge exposes no private store unless the integration declares it', () async {
      final bridge = await Bridge.start(project: temporary('mana-no-private-'), port: 0, momentsEnabled: false);
      addTearDown(bridge.close);
      expect((await call(bridge.url, bridge.token, '/moments/private-store', {})).code, 404);
    });

    test('a declared slot matching an Object prototype name is absent until written', () async {
      final f = await store(['constructor']);
      await f.request({'operation': 'claim', 'client': first});
      expect(await f.body({'operation': 'read', 'client': first, 'key': 'constructor'}), {'value': null});
      await f.request({'operation': 'write', 'client': first, 'key': 'constructor', 'value': 'private'});
      await f.restart();
      await f.request({'operation': 'claim', 'client': second});
      expect(await f.body({'operation': 'read', 'client': second, 'key': 'constructor'}), {'value': 'private'});
    });

    test('independent slot claims coexist and replacement revokes only that slot', () async {
      final f = await store(['session', 'task-creation']);
      expect((await f.request({'operation': 'claim', 'client': first})).status, 400);
      await f.request({'operation': 'claim', 'client': first, 'key': 'session'});
      await f.request({'operation': 'claim', 'client': second, 'key': 'task-creation'});
      expect((await f.request({'operation': 'write', 'client': first, 'key': 'session', 'value': secret})).status, 200);
      expect(
        (await f.request({'operation': 'write', 'client': second, 'key': 'task-creation', 'value': 'attempt'})).status,
        200,
      );
      final third = 'c' * 48;
      await f.request({'operation': 'claim', 'client': third, 'key': 'task-creation'});
      expect(
        (await f.request({'operation': 'write', 'client': second, 'key': 'task-creation', 'value': 'stale'})).status,
        409,
      );
      expect(await f.body({'operation': 'read', 'client': first, 'key': 'session'}), {'value': secret});
      expect(await f.body({'operation': 'read', 'client': third, 'key': 'task-creation'}), {'value': 'attempt'});
      await f.restart();
      expect((await f.request({'operation': 'read', 'client': first, 'key': 'session'})).status, 409);
      expect((await f.request({'operation': 'read', 'client': third, 'key': 'task-creation'})).status, 409);
    });
  });

  group('web actor', () {
    test('two actors share code bytes but expose independent uncached local configuration', () async {
      final dir = temporary('mana-web-actor-');
      File(p.join(dir, 'index.html')).writeAsStringSync('<html>actor</html>');
      File(p.join(dir, 'main.dart.js')).writeAsStringSync('// same immutable application');
      final a = await WebActor.start(
        artifact: dir,
        port: await freePort(),
        apiUrl: 'http://127.0.0.1:6001',
        bridgeUrl: 'http://127.0.0.1:6002',
        bridgeToken: 'a' * 48,
      );
      addTearDown(a.close);
      final b = await WebActor.start(
        artifact: dir,
        port: await freePort(),
        apiUrl: 'http://127.0.0.1:6003',
        bridgeUrl: 'http://127.0.0.1:6004',
        bridgeToken: 'b' * 48,
      );
      addTearDown(b.close);
      expect((await get('${a.url}/main.dart.js')).text, (await get('${b.url}/main.dart.js')).text);
      final response = await get('${a.url}/__moments_runtime');
      expect(response.headers.value('cache-control'), 'no-store');
      expect(response.headers.value('access-control-allow-origin'), isNull);
      final one = jsonDecode(response.text) as Map,
          two = jsonDecode((await get('${b.url}/__moments_runtime')).text) as Map;
      expect(one['apiUrl'], isNot(two['apiUrl']));
      expect(one['bridgeToken'], isNot(two['bridgeToken']));
      expect((await get('${a.url}/__moments_runtime', {'Origin': b.url})).status, 403);
      expect((await get('${a.url}/__moments_runtime', {'Sec-Fetch-Site': 'cross-site'})).status, 403);
      final outside = p.join(p.dirname(dir), 'outside-${uuidV4()}');
      File(outside).writeAsStringSync('private');
      addTearDown(() => File(outside).deleteSync());
      Link(p.join(dir, 'outside')).createSync(outside);
      final denied = await get('${a.url}/outside');
      expect([403, 404], contains(denied.status));
      expect(denied.text, isNot('private'));
      expect((await get('${a.url}/tasks', {'Accept': 'text/html'})).status, 200);
    });

    test('same-origin surfaces select independent bridges with no default or ambiguous fallback', () async {
      final dir = temporary('mana-surfaces-');
      File(p.join(dir, 'index.html')).writeAsStringSync('<html>surfaces</html>');
      File(p.join(dir, 'main.dart.js')).writeAsStringSync('// shared immutable code');
      final a = uuidV4(), b = uuidV4();
      final surfaces = <String, Map<String, Object?>>{
        a: {'bridgeUrl': 'http://127.0.0.1:6002', 'bridgeToken': 'a' * 48},
        b: {'bridgeUrl': 'http://127.0.0.1:6003', 'bridgeToken': 'b' * 48},
      };
      final port = await freePort();
      final host = await WebActor.start(artifact: dir, port: port, apiUrl: 'http://127.0.0.1:6001', surfaces: surfaces);
      addTearDown(host.close);
      Future<Map> read(String id) async =>
          jsonDecode((await get('${host.url}/__moments_runtime?momentsActor=$id')).text) as Map;
      final one = await read(a), two = await read(b);
      expect(one['version'], 2);
      expect(one['surface'], a);
      expect(two['surface'], b);
      expect(one['origin'], two['origin']);
      expect(one['apiUrl'], two['apiUrl']);
      expect(one['bridgeUrl'], isNot(two['bridgeUrl']));
      expect(one['bridgeToken'], isNot(two['bridgeToken']));
      for (final suffix in [
        '',
        '?momentsActor=${uuidV4()}',
        '?momentsActor=$a&momentsActor=$b',
        '?momentsActor=$a&extra=b',
      ]) {
        final response = await get('${host.url}/__moments_runtime$suffix');
        expect(response.status, 404, reason: suffix);
        expect(response.text.contains(one['bridgeToken'] as String), isFalse);
      }
      expect(
        (await get('${host.url}/__moments_runtime?momentsActor=$a', {'Origin': 'https://foreign.invalid'})).status,
        403,
      );
      await expectLater(
        WebActor.start(
          artifact: dir,
          port: await freePort(),
          apiUrl: 'http://127.0.0.1:6001',
          surfaces: surfaces,
          bridgeUrl: 'http://127.0.0.1:6002',
          bridgeToken: 'a' * 48,
        ),
        throwing('without a default'),
      );
      await expectLater(
        WebActor.start(
          artifact: dir,
          port: await freePort(),
          apiUrl: 'http://127.0.0.1:6001',
          surfaces: {a: surfaces[a]!, b: surfaces[a]!},
        ),
        throwing('independent bridge'),
      );
      // Mutating caller configuration cannot retarget an already running surface.
      surfaces[a]!['bridgeUrl'] = 'http://127.0.0.1:6999';
      expect((await read(a))['bridgeUrl'], one['bridgeUrl']);
    });
  });
}

/// The real filesystem file, created outside the test's IOOverrides zone.
File _RealFile(String path) => IOOverrides.runWithIOOverrides(() => File(path), _Plain());

final class _Plain extends IOOverrides {}
