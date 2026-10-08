import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState, uuidV4;
import 'package:moments/src/browser.dart';
import 'package:moments/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));
const origin = 'http://127.0.0.1:5316';

/// A browser host with real tabs in memory; its operations can be swapped.
final class Fixture {
  Fixture._(this.dir) : path = p.join(dir, 'host.sock');
  final String dir, path;
  final tabs = <String, String>{};
  var calls = 0, loseReply = false;
  List<Map<String, Object?>>? findOverride;
  BrowserHost? host;
  late Future<BrowserResult> Function(String url) open = (url) async {
    final id = 'tab-${++calls}';
    tabs[id] = url;
    if (loseReply) throw const MomentsError('Lost open acknowledgment');
    return {'id': id, 'status': 'present', 'url': url};
  };
  late Future<BrowserResult> Function(String url) find = (url) async => {
    'matches':
        findOverride ??
        [
          for (final MapEntry(key: id, value: value) in tabs.entries)
            if (value == url) {'id': id, 'status': 'present', 'url': value},
        ],
  };

  late final provider = BrowserProvider(
    id: 'host',
    open: (url) => open(url),
    find: (url) => find(url),
    inspect: (id) async =>
        tabs.containsKey(id) ? {'id': id, 'status': 'present', 'url': tabs[id]} : {'id': id, 'status': 'absent'},
    close: (id) async => tabs.remove(id),
  );
  late final client = browserSocketProvider(path: path, id: 'host');

  static Future<Fixture> start() async {
    final f = Fixture._(temporary('mana-browser-opening-'));
    await f.serve();
    addTearDown(() => f.host?.close());
    return f;
  }

  Future<void> serve() async =>
      host = await BrowserHost.serve(path: path, provider: provider, openOrigins: const [origin]);
  Future<void> restart() async {
    await host!.close();
    await serve();
  }

  String actor(String name) {
    final dir = p.join(this.dir, name);
    Directory(dir).createSync();
    return dir;
  }

  void dead(String dir) {
    final file = p.join(dir, 'browser.json');
    final record = (readJson(file)! as Map).cast<String, Object?>();
    (record['supervisor']! as Map)['pid'] = 2147483647;
    savePrivateState(file, record);
  }
}

void main() {
  test('automatic opening is durable, scoped and idempotent across host restart', () async {
    final f = await Fixture.start(), url = '$origin/tasks?momentsActor=${uuidV4()}';
    final first = await f.client.open!(url);
    expect(first['status'], 'present');
    expect(f.calls, 1);
    await f.restart();
    expect(await f.client.open!(url), first);
    expect(f.calls, 1);
    await f.client.close!(first['id']! as String);
    expect((await f.client.open!(url))['status'], 'absent');
    expect(f.calls, 1);
    await expectLater(f.client.open!(url.replaceFirst('/tasks?', '/different?')), throwing('refused'));
    await expectLater(f.client.open!(url.replaceFirst('5316', '5317')), throwing('refused'));
    await expectLater(f.client.open!('https://example.com/?momentsActor=${uuidV4()}'), throwing('refused'));
    expect(f.calls, 1);
  });

  test('lost opening response reconciles by nonce after host and supervisor recovery without opening twice', () async {
    final f = await Fixture.start(), actor = f.actor('actor');
    final boundary = allocateBrowserBoundary(actor);
    f.loseReply = true;
    await expectLater(boundary.open('$origin/tasks', f.client), throwing('refused'));
    expect(f.calls, 1);
    expect(f.tabs.length, 1);
    final record = (readJson(p.join(actor, 'browser.json'))! as Map).cast<String, Object?>();
    expect(record['phase'], 'opening');
    expect(record['openingProvider'], 'host');
    f.dead(actor);
    await f.restart();
    final recovered = recoverBrowserBoundary(actor);
    await expectLater(recovered.open('$origin/tasks', f.client), throwing('cannot be replayed'));
    await recovered.close(f.client);
    recovered.assertClosed();
    expect(f.tabs, isEmpty);
    expect(f.calls, 1);
  });

  test('unknown or ambiguous pending opening retains resources instead of guessing absence or reopening', () async {
    final f = await Fixture.start(), url = '$origin/tasks?momentsActor=${uuidV4()}';
    await expectLater(f.client.resolve!(url), throwing('refused'));
    expect(f.calls, 0);
    f.loseReply = true;
    await expectLater(f.client.open!(url), throwing('refused'));
    f.findOverride = [];
    await expectLater(f.client.open!(url), throwing('refused'));
    expect(f.calls, 1);
    f.findOverride = [
      {'id': 'tab-1', 'status': 'present', 'url': url},
      {'id': 'extra', 'status': 'present', 'url': url},
    ];
    await expectLater(f.client.resolve!(url), throwing('refused'));
    expect(f.calls, 1);
    expect(f.tabs.length, 1);
  });

  test('automatic boundary confirms attachment and refuses another provider or changed tab', () async {
    final f = await Fixture.start(), boundary = allocateBrowserBoundary(f.actor('actor'));
    final result = await boundary.open('$origin/tasks', f.client);
    expect(boundary.phase, 'attached');
    final c = f.client;
    await expectLater(
      boundary.close(
        BrowserProvider(id: 'foreign', open: c.open, resolve: c.resolve, inspect: c.inspect, close: c.close),
      ),
      throwing('Matching browser'),
    );
    final tab = result.tab!['id']! as String;
    f.tabs[tab] = '$origin/other';
    await expectLater(boundary.close(f.client), throwing('refused'));
    expect(f.tabs.length, 1);
    f.tabs[tab] = result.url;
    await boundary.close(f.client);
    expect(f.tabs, isEmpty);
  });

  test('host-confirmed settled absence cancels an unopened nonce durably without inventing a tab', () async {
    final f = await Fixture.start(), dir = f.actor('actor');
    final boundary = allocateBrowserBoundary(dir);
    f.open = (_) async => throw const MomentsError('Dispatch failed before opening');
    await expectLater(boundary.open('$origin/tasks', f.client), throwing('refused'));
    f.find = (_) async => {'matches': <Object?>[]};
    await expectLater(boundary.close(f.client), throwing('refused'));
    f.find = (_) async => {'matches': <Object?>[], 'settled': true};
    expect(await boundary.close(f.client), {'status': 'closed', 'opened': false});
    boundary.assertClosed();
    f.dead(dir);
    await f.restart();
    recoverBrowserBoundary(dir).assertClosed();
    expect(await f.client.open!(boundary.url!), {'status': 'absent', 'unopened': true, 'url': boundary.url});
    expect(f.calls, 0);
  });

  test(
    'unauthorized opening is terminal and cleanable without dispatch, including old refusal without intent',
    () async {
      final f = await Fixture.start(), boundary = allocateBrowserBoundary(f.actor('refused'));
      await expectLater(boundary.open('http://127.0.0.1:5319/tasks', f.client), throwing('refused'));
      expect(f.calls, 0);
      expect(f.tabs, isEmpty);
      expect(await boundary.close(f.client), {'status': 'closed', 'opened': false});
      boundary.assertClosed();
      await f.restart();
      expect(await f.client.open!(boundary.url!), {'status': 'absent', 'unopened': true, 'url': boundary.url});
      await expectLater(f.client.resolve!(boundary.url!.replaceFirst('/tasks?', '/different?')), throwing('refused'));
      final legacy = 'http://127.0.0.1:5320/tasks?momentsActor=${uuidV4()}';
      expect(await f.client.resolve!(legacy), {'status': 'absent', 'unopened': true, 'url': legacy});
      await f.restart();
      expect((await f.client.open!(legacy))['unopened'], true);
      expect(f.calls, 0);
      expect(f.tabs, isEmpty);
    },
  );
}
