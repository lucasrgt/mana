import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;
import 'package:moments/src/browser.dart';
import 'package:moments/src/flutter_actor.dart';
import 'package:moments/src/layers.dart';
import 'package:moments/src/manifest.dart';
import 'package:moments/src/materializer.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

Future<int> freePort() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  await server.close();
  return port;
}

Future<String> fetch(String url, {String accept = '*/*'}) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('accept', accept);
    final response = await request.close();
    return await utf8.decoder.bind(response).join();
  } finally {
    client.close(force: true);
  }
}

final class Backend implements ActorBackend {
  final events = <List<Object?>>[];
  Future<void> Function()? startWith;

  int count(String kind) => events.where((e) => e.first == kind).length;

  @override
  Map<String, Object?> allocate({required String dir}) => {'dir': dir, 'url': 'http://127.0.0.1:6001'};
  @override
  Future<void> start(
    Map<String, Object?> handle, {
    required String database,
    required LayerHandle databaseHandle,
    required String databaseDirectory,
    required String webOrigin,
  }) async {
    events.add([
      'start',
      {
        'database': database,
        'databaseHandle': databaseHandle,
        'databaseDirectory': databaseDirectory,
        'webOrigin': webOrigin,
      },
    ]);
    await startWith?.call();
  }

  @override
  Future<void> stop(Map<String, Object?> handle) async => events.add(['stop']);
}

/// Tiny assets exercise the actual HTTP/process/bridge lifecycle, not Flutter
/// rendering or Ash behavior; the consumer Moment proof covers that boundary.
final class Fixture {
  Fixture._(this.dir, this.actor, this.artifact, this.manifestFile, this.world);
  final String dir, actor, artifact, manifestFile;
  final World world;
  final backend = Backend();

  static Fixture create(String prefix) {
    final dir = temporary(prefix), actor = p.join(dir, 'actor'), artifact = p.join(dir, 'web');
    Directory(actor).createSync();
    Directory(artifact).createSync();
    File(p.join(artifact, 'index.html')).writeAsStringSync('actor services fixture');
    File(p.join(artifact, 'main.dart.js')).writeAsStringSync('// immutable fixture');
    final manifestFile = p.join(dir, 'moments/manifest.json');
    writeJson(manifestFile, {
      'version': 3,
      'protocol': protocol,
      'watch': <Object>[],
      'properties': {
        'route': {
          'enum': ['/'],
        },
      },
      'moments': {
        'root': {
          'description': 'Root',
          'projection': {'route': '/'},
          'checks': <Object>[],
        },
      },
    });
    final manifest = readManifest(manifestFile)['recipeHash']! as String;
    final world = World(id: uuidV4(), name: 'root', dir: dir, materializedMoment: null, manifest: manifest);
    world.handles['actor'] = {'dir': actor};
    world.handles['db'] = {'database': 'isolated_fixture'};
    final session = p.join(actor, 'ui-session.json');
    File(session).writeAsStringSync(
      jsonEncode({
        'version': 2,
        'active': 'root',
        'states': {
          'root': {
            'name': 'root',
            'recipeHash': manifest,
            'projection': {'route': '/'},
          },
        },
      }),
    );
    Process.runSync('chmod', ['600', session]);
    return Fixture._(dir, actor, artifact, manifestFile, world);
  }

  ActorFrontend get frontend => ActorFrontend.sharedDebugArtifact(cwd: dir, artifact: artifact);
}

void main() {
  setUpAll(compileCli);

  group('services', () {
    late Fixture f;
    late FlutterActorServices services;
    late ActorHandle handle;
    var browserClosed = true;

    FlutterActorServices create({ActorFrontend? frontend}) => FlutterActorServices(
      project: f.dir,
      manifestFile: f.manifestFile,
      backend: f.backend,
      frontend: frontend ?? f.frontend,
      worker: cliProgram,
      assertBrowserClosed: (_) {
        f.backend.events.add(['browser']);
        if (!browserClosed) throw StateError('Browser closure unconfirmed');
      },
    );

    setUp(() {
      browserClosed = true;
      f = Fixture.create('mana-actor-services-');
      services = create();
      handle = services.allocate(f.world);
      addTearDown(() async {
        browserClosed = true;
        await services.stop(handle);
      });
    });

    test('owned web process and bridge preserve per-actor configuration; closure refusal retains services', () async {
      final port = await freePort();
      await services.start(handle, ActorLaunch(port: port));
      expect(handle.flutter!.inspect().running, isTrue);
      expect(await fetch(handle.url!, accept: 'text/html'), 'actor services fixture');
      final config = jsonDecode(await fetch('${handle.url}__moments_runtime')) as Map;
      expect(config['apiUrl'], handle.api!['url']);
      expect(config['bridgeUrl'], handle.bridge!.url);
      expect(config['bridgeToken'], handle.bridge!.token);
      expect(f.backend.events.first, [
        'start',
        {
          'database': 'isolated_fixture',
          'databaseHandle': f.world.handles['db'],
          'databaseDirectory': p.join(f.dir, 'db'),
          'webOrigin': 'http://127.0.0.1:$port',
        },
      ]);
      browserClosed = false;
      await expectLater(services.stop(handle), throwing('Browser closure'));
      expect(handle.flutter!.inspect().running, isTrue);
      expect(f.backend.count('stop'), 0);
      browserClosed = true;
      await services.stop(handle);
      expect(handle.flutter!.inspect().present, isFalse);
      expect(File(p.join(f.actor, '.runtime.json')).existsSync(), isFalse);
      await services.stop(handle);
      expect(f.backend.count('stop'), 1);
      await expectLater(services.start(handle, ActorLaunch(port: port)), throwing('cannot be replayed'));
    });

    test('failed backend validation retains its handle and cannot replay startup', () async {
      final port = await freePort();
      await expectLater(
        services.start(
          handle,
          ActorLaunch(port: port, validateBackend: (_) async => throw StateError('Session expired')),
        ),
        throwing('Session expired'),
      );
      expect(handle.api, isNotNull);
      expect(handle.bridge, isNull);
      expect(handle.flutter, isNull);
      await expectLater(services.start(handle, ActorLaunch(port: port)), throwing('cannot be replayed'));
      await services.stop(handle);
      expect(f.backend.count('stop'), 1);
    });

    test('web startup failure leaves partial services stoppable without rerunning the backend', () async {
      final port = await freePort();
      File(p.join(f.artifact, 'main.dart.js')).deleteSync();
      await expectLater(services.start(handle, ActorLaunch(port: port)), throwing('exited during startup'));
      expect([handle.api, handle.bridge, handle.flutter], everyElement(isNotNull));
      await services.stop(handle);
      expect(handle.flutter!.inspect().present, isFalse);
      expect(File(p.join(f.actor, '.runtime.json')).existsSync(), isFalse);
      expect(f.backend.count('start'), 1);
      expect(f.backend.count('stop'), 1);
    });

    test('cleanup waits for a pending start and refuses foreign handles and route origins', () async {
      final port = await freePort();
      for (final route in ['/\\foreign.invalid/', '//foreign.invalid/', 'relative']) {
        await expectLater(
          services.start(handle, ActorLaunch(port: port, route: route)),
          throwsA(anything),
          reason: route,
        );
      }
      expect(f.backend.events, isEmpty);
      final release = Completer<void>();
      f.backend.startWith = () => release.future;
      final starting = services.start(
        handle,
        ActorLaunch(port: port, validateBackend: (_) async => throw StateError('Stop after pending start')),
      );
      final stopping = services.stop(handle);
      await expectLater(services.start(handle, ActorLaunch(port: port)), throwing('cannot be replayed'));
      expect(f.backend.count('stop'), 0);
      release.complete();
      await expectLater(starting, throwing('Stop after pending start'));
      await stopping;
      expect(f.backend.count('stop'), 1);
      expect(() => create().stop(handle), throwing('another service runtime'));
    });

    test(
      'prebuilt Android actors require dynamic bootstrap and validate the artifact before backend effects',
      () async {
        final binary = p.join(f.dir, 'app-debug.apk');
        ActorFrontend android({bool bootstrap = false}) => ActorFrontend.android(
          cwd: f.dir,
          device: 'android:emulator-5554',
          applicationId: 'dev.mana.fixture',
          applicationBinary: binary,
          runtimeBootstrap: bootstrap,
        );
        expect(() => create(frontend: android()), throwing('requires runtime bootstrap'));
        final native = create(frontend: android(bootstrap: true));
        Future<void> start() async {
          final owned = native.allocate(f.world);
          try {
            await native.start(owned, const ActorLaunch(port: 5316));
          } finally {
            await native.stop(owned);
          }
        }

        await expectLater(start(), throwing('regular nonempty APK'));
        expect(f.backend.events, isEmpty);
        File(binary).writeAsStringSync('');
        await expectLater(start(), throwing('regular nonempty APK'));
        expect(f.backend.events, isEmpty);
        File(binary).deleteSync();
        Link(binary).createSync(p.join(f.artifact, 'index.html'));
        await expectLater(start(), throwing('regular nonempty APK'));
        expect(f.backend.events, isEmpty);
      },
    );
  });

  group('runtime', () {
    test('ambiguous browser opening retains live actor services until the same tab is reconciled', () async {
      final f = Fixture.create('mana-managed-actor-');
      var opens = 0, closed = 0, ambiguous = true;
      String? actual;
      final runtime = FlutterActorRuntime(
        project: f.dir,
        manifestFile: f.manifestFile,
        backend: f.backend,
        frontend: f.frontend,
        worker: cliProgram,
        browserProvider: BrowserProvider(
          id: 'host',
          open: (url) async {
            opens++;
            actual = url;
            throw StateError('Opening reply lost');
          },
          resolve: (_) async {
            if (ambiguous) throw StateError('Opening is ambiguous');
            return {'id': 'owned', 'status': closed > 0 ? 'absent' : 'present', 'url': actual};
          },
          inspect: (id) async => {'id': id, 'status': closed > 0 ? 'absent' : 'present', 'url': actual},
          close: (_) async => closed++,
        ),
        configure: (_) async => ActorLaunch(port: await freePort()),
      );
      final handle = runtime.allocate(f.world);
      f.world.runtime = handle;
      addTearDown(() async {
        ambiguous = false;
        await runtime.stop(handle);
      });
      await expectLater(runtime.start(handle, f.world), throwing('reply lost'));
      await expectLater(runtime.stop(handle), throwing('ambiguous'));
      expect(handle.flutter!.inspect().running, isTrue);
      expect((f.backend.count('stop'), opens, closed), (0, 1, 0));
      ambiguous = false;
      await runtime.stop(handle);
      expect(handle.flutter!.inspect().present, isFalse);
      runtime.assertStopped(f.world.handles['actor']!);
      expect((f.backend.count('stop'), opens, closed), (1, 1, 1));
    });

    test('stop waits for a failed pending backend start and does not open a late browser', () async {
      final f = Fixture.create('mana-managed-actor-');
      var opens = 0;
      final runtime = FlutterActorRuntime(
        project: f.dir,
        manifestFile: f.manifestFile,
        backend: f.backend,
        frontend: f.frontend,
        worker: cliProgram,
        browserProvider: BrowserProvider(
          id: 'host',
          open: (_) async {
            opens++;
            throw StateError('Late browser');
          },
          resolve: (_) async => {'id': 'owned', 'status': 'absent'},
          inspect: (id) async => {'id': id, 'status': 'absent'},
          close: (_) async {},
        ),
        configure: (_) async => ActorLaunch(port: await freePort()),
      );
      final handle = runtime.allocate(f.world);
      f.world.runtime = handle;
      final fail = Completer<void>();
      f.backend.startWith = () => fail.future;
      final starting = runtime.start(handle, f.world);
      while (f.backend.count('start') == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final stopping = runtime.stop(handle);
      fail.completeError(StateError('Backend failed'));
      await expectLater(starting, throwing('Backend failed'));
      await stopping;
      expect((f.backend.count('stop'), opens), (1, 0));
      await expectLater(runtime.start(handle, f.world), throwing('cannot be replayed'));
    });

    test('native runtime has a separate recovery identity and never allocates a browser boundary', () async {
      final dir = temporary('mana-native-runtime-');
      final world = World(id: uuidV4(), name: 'root', dir: dir, materializedMoment: null, manifest: 'a' * 64);
      world.handles['actor'] = {'dir': p.join(dir, 'actor')};
      world.handles['db'] = {'database': 'fixture'};
      final backend = Backend()..startWith = () async => throw StateError('Backend stopped before device allocation');
      FlutterActorRuntime create({BrowserProvider? browserProvider}) => FlutterActorRuntime(
        project: dir,
        manifestFile: p.join(dir, 'manifest.json'),
        backend: backend,
        frontend: ActorFrontend.android(cwd: dir, device: 'android:emulator-5554', applicationId: 'dev.mana.fixture'),
        browserProvider: browserProvider,
        configure: (_) => const ActorLaunch(port: 5316),
      );
      expect(() => create(browserProvider: BrowserProvider(id: 'host')), throwing('do not use a browser'));
      final runtime = create();
      expect(runtime.type, 'ash-flutter-android');
      final handle = runtime.allocate(world);
      world.runtime = handle;
      await expectLater(runtime.start(handle, world), throwing('Backend stopped'));
      await runtime.stop(handle);
      expect(handle.browser, isNull);
      expect(handle.android, isNull);
      runtime.assertStopped(world.handles['actor']!);
    });
  });
}
