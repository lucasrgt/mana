import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart'
    show ArtifactFingerprint, artifactFingerprint, fingerprintJson, savePrivateState, uuidV4;
import 'package:moments/src/android_actor.dart';
import 'package:moments/src/artifact_cache.dart';
import 'package:moments/src/browser.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));
String hash(String value) => sha256.convert(utf8.encode(value)).toString();
void chmod(String mode, String path) => Process.runSync('chmod', [mode, path]);

void main() {
  group('native launch', () {
    const valid = {
      'apiUrl': 'http://127.0.0.1:6001',
      'bridgeUrl': 'http://127.0.0.1:6002',
      'bridgeToken': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    };
    String route(Map<String, Object?> value) => nativeMomentRoute(
      apiUrl: value['apiUrl'] as String? ?? '',
      bridgeUrl: value['bridgeUrl'] as String? ?? '',
      bridgeToken: value['bridgeToken'] as String? ?? '',
    );

    test('native configuration uses an encoded launch envelope, separate from the product route', () {
      final url = Uri.parse('http://127.0.0.1${route(valid)}');
      expect(url.path, '/__mana_moments');
      expect(jsonDecode(url.queryParameters['configuration']!), {'version': 1, ...valid});
    });

    test('native launch rejects foreign services, URL credentials and missing capability', () {
      for (final key in ['apiUrl', 'bridgeUrl']) {
        for (final value in [
          'https://example.test',
          'http://localhost:6001',
          'http://127.0.0.1:6001/path',
          'http://user:secret@127.0.0.1:6001',
          'http://127.0.0.1:6001?token=x',
          'http://127.0.0.1:6001#fragment',
          'http://127.0.0.1:99999',
          null,
        ]) {
          expect(() => route({...valid, key: value}), throwing('local services'), reason: '$key $value');
        }
      }
      for (final token in ['', null, 'secret', 'a' * 49]) {
        expect(() => route({...valid, 'bridgeToken': token}), throwing('capability'));
      }
    });
  });

  group('android binary', () {
    ({String file, String applicationId}) fixture() {
      final file = p.join(temporary('mana-apk-'), 'fixture.apk');
      File(file).writeAsStringSync('SDK inspection fixture');
      return (file: file, applicationId: 'dev.mana.fixture');
    }

    test('pins bytes after SDK package/debug validation; rejects replacement before another inspection', () {
      final f = fixture(), calls = <String>[];
      final binary = AndroidBinary(
        file: f.file,
        applicationId: f.applicationId,
        inspect: (operation, _) {
          calls.add(operation);
          return operation == 'application-id' ? f.applicationId : 'true';
        },
      );
      final first = binary.read();
      expect(binary.read(), first);
      expect(calls, ['application-id', 'debuggable']);
      File(f.file).writeAsStringSync('replacement');
      expect(binary.read, throwing('changed between actors'));
      expect(calls.length, 2);
    });

    test(
      'foreign package, release artifact, failed analyzer and changing inspection never yield a launch identity',
      () {
        final f = fixture();
        for (final values in [
          ['dev.foreign.app', 'true'],
          [f.applicationId, 'false'],
        ]) {
          expect(
            AndroidBinary(
              file: f.file,
              applicationId: f.applicationId,
              inspect: (op, _) => values[op == 'application-id' ? 0 : 1],
            ).read,
            throwing('debug and match'),
          );
        }
        expect(
          AndroidBinary(
            file: f.file,
            applicationId: f.applicationId,
            inspect: (_, _) => throw Exception('private SDK details'),
          ).read,
          throwsA(predicate((e) => '$e'.startsWith('Cannot inspect Android APK'))),
        );
        expect(
          AndroidBinary(
            file: f.file,
            applicationId: f.applicationId,
            inspect: (op, _) {
              File(f.file).writeAsStringSync('changed during inspection');
              return op == 'application-id' ? f.applicationId : 'true';
            },
          ).read,
          throwing('changed during inspection'),
        );
      },
    );
  });

  group('artifact cache', () {
    ({String dir, String cacheDir, ArtifactCache cache, String source, String key}) fixture() {
      final dir = temporary('mana-build-cache-');
      final cacheDir = p.join(dir, 'cache'), source = p.join(dir, 'source');
      Directory(source).createSync();
      File(p.join(source, 'app.js')).writeAsStringSync('first');
      return (
        dir: dir,
        cacheDir: cacheDir,
        cache: ArtifactCache(cacheDir, names: const ['web']),
        source: source,
        key: 'a' * 64,
      );
    }

    test('cache requires exact input key and restores independent verified copies', () async {
      final f = fixture();
      Map<String, String> out(String name) => {'web': p.join(f.dir, name)};
      expect((await f.cache.restore(key: f.key, targets: out('absent')))['status'], 'miss');
      await f.cache.publish(key: f.key, artifacts: {'web': f.source});
      expect((await f.cache.restore(key: 'b' * 64, targets: out('wrong')))['status'], 'miss');
      expect((await f.cache.restore(key: f.key, targets: out('one')))['status'], 'hit');
      File(p.join(f.dir, 'one/app.js')).writeAsStringSync('changed');
      await f.cache.restore(key: f.key, targets: out('two'));
      expect(File(p.join(f.dir, 'two/app.js')).readAsStringSync(), 'first');
      await expectLater(f.cache.restore(key: f.key, targets: out('two')), throwing('fresh'));
    });

    test('corruption or partial publication is quarantined and never reused', () async {
      final f = fixture();
      Map<String, String> out(String name) => {'web': p.join(f.dir, name)};
      await f.cache.publish(key: f.key, artifacts: {'web': f.source});
      File(p.join(f.cacheDir, f.key, 'web/app.js')).writeAsStringSync('corrupt');
      expect((await f.cache.restore(key: f.key, targets: out('bad')))['reason'], 'invalid');
      expect(Directory(p.join(f.dir, 'bad')).existsSync(), isFalse);
      expect(Directory(p.join(f.cacheDir, '.rejected')).listSync().length, 1);
      await f.cache.publish(key: f.key, artifacts: {'web': f.source});
      expect((await f.cache.restore(key: f.key, targets: out('good')))['status'], 'hit');
      final partial = 'c' * 64;
      Directory(p.join(f.cacheDir, partial)).createSync();
      chmod('700', p.join(f.cacheDir, partial));
      expect((await f.cache.restore(key: partial, targets: out('partial')))['reason'], 'invalid');
    });

    test('external and absolute symlinks cannot publish artifacts; relative internal links survive copy', () async {
      final f = fixture();
      Link(p.join(f.source, 'escape')).createSync('/etc/hosts');
      await expectLater(f.cache.publish(key: f.key, artifacts: {'web': f.source}), throwing('escapes'));
      Link(p.join(f.source, 'escape')).deleteSync();
      Link(p.join(f.source, 'alias')).createSync('app.js');
      await f.cache.publish(key: f.key, artifacts: {'web': f.source});
      await f.cache.restore(key: f.key, targets: {'web': p.join(f.dir, 'linked')});
      expect(File(p.join(f.dir, 'linked/alias')).readAsStringSync(), 'first');
    });
  });

  group('browser boundary', () {
    ({
      String dir,
      BrowserBoundary browser,
      String url,
      BrowserProvider provider,
      List<int> closes,
      void Function(String) change,
    })
    fixture() {
      final dir = temporary('mana-browser-');
      final browser = allocateBrowserBoundary(dir), url = browser.expect('http://127.0.0.1:5316/tasks');
      var open = true, actual = url;
      final closes = <int>[];
      final provider = BrowserProvider(
        id: 'cua',
        inspect: (id) async => {'id': id, 'status': open ? 'present' : 'absent', 'url': actual},
        close: (_) async {
          closes.add(1);
          open = false;
        },
      );
      return (
        dir: dir,
        browser: browser,
        url: url,
        provider: provider,
        closes: closes,
        change: (value) => actual = value,
      );
    }

    test('pending browser identity prevents cleanup and live supervisor prevents recovery', () async {
      final f = fixture();
      await expectLater(f.browser.close(f.provider), throwing('no tab identity'));
      expect(() => recoverBrowserBoundary(f.dir), throwing('still alive'));
      expect(f.browser.assertClosed, throwing('unconfirmed'));
    });

    test('owned tab close requires observed absence and is idempotent', () async {
      final f = fixture();
      await f.browser.attach(provider: f.provider, id: 'tab-1');
      await expectLater(
        f.browser.close(BrowserProvider(id: 'cua', inspect: f.provider.inspect, close: (_) async {})),
        throwing('remains open'),
      );
      await f.browser.close(f.provider);
      f.browser.assertClosed();
      await f.browser.close(null);
      expect(f.closes.length, 1);
    });

    test('a different provider or reused/navigated tab cannot be closed', () async {
      final f = fixture();
      await f.browser.attach(provider: f.provider, id: 'tab-1');
      await expectLater(
        f.browser.close(BrowserProvider(id: 'other', inspect: f.provider.inspect, close: f.provider.close)),
        throwing('Matching browser provider'),
      );
      f.change('http://127.0.0.1:5316/tasks');
      await expectLater(f.browser.close(f.provider), throwing('identity changed'));
      expect(f.closes, isEmpty);
    });

    test('recovery consults the provider again and never reopens the tab', () async {
      final f = fixture();
      await f.browser.attach(provider: f.provider, id: 'tab-1');
      final file = p.join(f.dir, 'browser.json');
      final record = (readJson(file)! as Map).cast<String, Object?>();
      (record['supervisor']! as Map)['pid'] = 2147483647;
      savePrivateState(file, record);
      final recovered = recoverBrowserBoundary(f.dir);
      expect(() => recovered.expect(f.url), throwing('replayed'));
      await recovered.close(f.provider);
      expect(f.closes.length, 1);
      recovered.assertClosed();
    });
  });

  group('artifact fingerprint', () {
    ({String root, String file, ArtifactFingerprint scanner}) fixture() {
      final root = temporary('mana-fingerprint-'), file = p.join(root, 'app');
      File(file).writeAsStringSync('first');
      chmod('600', file);
      return (root: root, file: file, scanner: ArtifactFingerprint(root));
    }

    Map<String, Object?> scan(ArtifactFingerprint scanner, {bool fresh = false}) =>
        fingerprintJson(scanner.snapshot(fresh: fresh));
    Map<String, Object?> oneShot(String root) => fingerprintJson(artifactFingerprint(root));

    test('one-shot and retained scanners preserve the sha256-tree-v1 byte contract', () {
      final (:root, file: _, :scanner) = fixture();
      final expected = {
        'algorithm': 'sha256-tree-v1',
        'sha256': hash('${jsonEncode(['file', 'app', 0x180, hash('first')])}\n'),
        'files': 1,
      };
      expect(oneShot(root), expected);
      expect(scan(scanner), expected);
      expect(scan(scanner), expected);
      expect(scan(scanner, fresh: true), expected);
    });

    test('same-size write with restored mtime and same-path inode replacement invalidate cached bytes', () async {
      final (:root, :file, :scanner) = fixture();
      final first = scan(scanner), modified = File(file).lastModifiedSync();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      File(file).writeAsStringSync('other');
      File(file).setLastModifiedSync(modified);
      final changed = scan(scanner);
      expect(changed['sha256'], isNot(first['sha256']));
      expect(changed, oneShot(root));
      final replacement = p.join(root, 'replacement');
      File(replacement).writeAsStringSync('third');
      chmod('600', replacement);
      File(replacement).setLastModifiedSync(modified);
      File(replacement).renameSync(file);
      expect(scan(scanner)['sha256'], isNot(changed['sha256']));
      expect(scan(scanner), oneShot(root));
    });

    test('additions, removals and file/directory modes are checked on every tree scan', () {
      final (:root, :file, :scanner) = fixture();
      var last = scan(scanner);
      for (final change in <void Function()>[
        () => chmod('700', file),
        () {
          Directory(p.join(root, 'assets')).createSync();
          chmod('700', p.join(root, 'assets'));
        },
        () => File(p.join(root, 'assets/font')).writeAsStringSync('font'),
        () => chmod('755', p.join(root, 'assets')),
        () => File(p.join(root, 'assets/font')).deleteSync(),
        () => Directory(p.join(root, 'assets')).deleteSync(recursive: true),
      ]) {
        change();
        final next = scan(scanner);
        expect(next['sha256'], isNot(last['sha256']));
        expect(next, oneShot(root));
        last = next;
      }
    });

    test('links describe their target without reading outside the artifact; type changes clear file reuse', () {
      final (:root, :file, :scanner) = fixture();
      final first = scan(scanner);
      File(file).deleteSync();
      Link(file).createSync('/not/read/by/this/fingerprint');
      final linked = scan(scanner);
      expect(linked['sha256'], isNot(first['sha256']));
      expect(linked, {
        'algorithm': 'sha256-tree-v1',
        'sha256': hash('${jsonEncode(['link', 'app', '/not/read/by/this/fingerprint'])}\n'),
        'files': 1,
      });
      Link(file).deleteSync();
      File(file).writeAsStringSync('first');
      chmod('600', file);
      expect(scan(scanner), first);
    });
  });

  group('browser socket host', () {
    Future<
      ({String dir, String path, String url, BrowserProvider client, List<int> closed, void Function(String) change})
    >
    fixture({bool reveal = false}) async {
      final dir = temporary('mana-browser-rpc-'), path = p.join(dir, 'host.sock');
      final url = 'http://127.0.0.1:5316/tasks?momentsActor=${uuidV4()}';
      var live = true, current = url;
      final closed = <int>[];
      final host = await BrowserHost.serve(
        path: path,
        tabs: [(id: 'owned', url: url)],
        provider: BrowserProvider(
          id: 'host',
          inspect: (id) async => {'id': id, 'status': live ? 'present' : 'absent', 'url': current},
          close: (_) async {
            closed.add(1);
            live = false;
          },
          reveal: reveal ? (id) async => {'id': id} : null,
        ),
      );
      addTearDown(host.close);
      return (
        dir: dir,
        path: path,
        url: url,
        client: browserSocketProvider(path: path, id: 'host'),
        closed: closed,
        change: (value) => current = value,
      );
    }

    test('private socket host closes only its bound tab and confirms absence', () async {
      final f = await fixture();
      expect((await f.client.inspect!('owned'))['status'], 'present');
      await expectLater(f.client.close!('unowned'), throwing('refused'));
      expect(f.closed, isEmpty);
      await f.client.close!('owned');
      await f.client.close!('owned');
      expect(f.closed.length, 1);
      expect((await f.client.inspect!('owned'))['status'], 'absent');
    });

    test('wrong provider or a navigated tab is refused without closing', () async {
      final f = await fixture();
      await expectLater(browserSocketProvider(path: f.path, id: 'other').close!('owned'), throwing('refused'));
      f.change('http://127.0.0.1:5316/tasks');
      await expectLater(f.client.close!('owned'), throwing('refused'));
      expect(f.closed, isEmpty);
    });

    test('a publicly accessible socket directory is refused', () async {
      final f = await fixture();
      chmod('755', f.dir);
      expect(() => browserSocketProvider(path: f.path, id: 'host'), throwing('private'));
      chmod('700', f.dir);
    });

    test('reveal requires an owned present surface and a matching host capability', () async {
      final dir = temporary('mana-reveal-'), path = p.join(dir, 'host.sock');
      final url = 'http://127.0.0.1:5316/tasks?momentsActor=${uuidV4()}';
      var live = true, revealed = 0, current = url;
      final host = await BrowserHost.serve(
        path: path,
        tabs: [(id: 'owned', url: url)],
        provider: BrowserProvider(
          id: 'host',
          inspect: (id) async => {'id': id, 'status': live ? 'present' : 'absent', 'url': current},
          close: (_) async => live = false,
          reveal: (id) async {
            revealed++;
            return {'id': id};
          },
        ),
      );
      addTearDown(host.close);
      final client = browserSocketProvider(path: path, id: 'host');
      await expectLater(client.reveal!('unowned'), throwing('refused'));
      expect(revealed, 0);
      expect((await client.reveal!('owned'))['status'], 'present');
      expect(revealed, 1);
      current = 'http://127.0.0.1:5316/other';
      await expectLater(client.reveal!('owned'), throwing('refused'));
      expect(revealed, 1);
      current = url;
      await client.close!('owned');
      await expectLater(client.reveal!('owned'), throwing('refused'));
      expect(revealed, 1);
      final unsupported = await fixture();
      await expectLater(unsupported.client.reveal!('owned'), throwing('refused'));
    });
  });
}
