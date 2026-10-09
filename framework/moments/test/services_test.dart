import 'dart:convert';
import 'dart:io';

import 'package:moments/src/services.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

final dart = Platform.resolvedExecutable;
List<String> sh(String script) => ['sh', '-c', script];

final class Fixture {
  Fixture._(this.cwd, this.port);
  final String cwd;
  final int port;
  late final ServiceDefinition definition;
  late final Services manager;

  static Future<Fixture> start() async {
    final f = Fixture._(temporary('moment-service-'), await freePort());
    File(p.join(f.cwd, 'source')).writeAsStringSync('one');
    f.definition = f.define();
    f.manager = f.services(f.definition);
    return f;
  }

  ServiceDefinition define({
    List<String>? prepare,
    List<String>? compile,
    List<String>? serve,
    Map<String, String> environment = const {},
    Duration? commandTimeout,
  }) => ServiceDefinition(
    name: 'test',
    cwd: cwd,
    port: port,
    watch: const ['source'],
    timeout: const Duration(seconds: 20),
    commandTimeout: commandTimeout,
    environment: environment,
    prepare: prepare ?? sh('echo once >> prepared'),
    compile: compile ?? sh('[ "\$(cat source)" != bad ]'),
    serve: serve ?? [dart, p.join(package, 'test/programs/source_server.dart'), '$port'],
    ready: () async {
      try {
        await read();
        return true;
      } on Object {
        return false;
      }
    },
  );

  Services services(ServiceDefinition definition, {bool prepareOnStart = true, ServiceLifecycle? lifecycle}) {
    final services = Services(
      definitions: [definition],
      directory: cwd,
      log: (_) {},
      prepareOnStart: prepareOnStart,
      lifecycle: lifecycle,
    );
    addTearDown(services.close);
    return services;
  }

  Future<Map<String, Object?>> read() async {
    final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
    try {
      final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port'))).close();
      return (jsonDecode(await utf8.decoder.bind(response).join()) as Map).cast();
    } finally {
      client.close(force: true);
    }
  }

  void write(String text) => File(p.join(cwd, 'source')).writeAsStringSync(text);
}

final class FakeLifecycle implements ServiceLifecycle {
  @override
  void track(Process child, String role) {}
  @override
  Map<String, String> environment() => {'MANA_RESOURCE_RUN': 'owned-run'};
}

void main() {
  test('owned service reuses data, recompiles edits, retains old server on failure and recovers', () async {
    final f = await Fixture.start();
    await f.manager.preflight();
    await f.manager.ensure();
    final first = await f.read();
    await f.manager.ensure();
    expect(await f.read(), first);
    f.write('two');
    await f.manager.ensure();
    final second = await f.read();
    expect(second['value'], 'two');
    expect(second['pid'], isNot(first['pid']));
    f.write('bad');
    await expectLater(f.manager.ensure(), throwing('command failed'));
    expect(f.manager.status().first['phase'], 'error');
    expect(await f.read(), second);
    f.write('fixed');
    await f.manager.ensure();
    expect((await f.read())['value'], 'fixed');
    expect(File(p.join(f.cwd, 'prepared')).readAsStringSync(), 'once\n', reason: 'Refresh must not reseed');
    await f.manager.close();
    await assertFreePort(f.port);
  });

  test('occupied endpoint is rejected without stopping the existing service', () async {
    final f = await Fixture.start();
    await f.manager.ensure();
    final before = await f.read();
    final other = f.services(f.definition);
    await expectLater(other.preflight(), throwing('already in use'));
    await expectLater(other.ensure(), throwing('already in use'));
    await other.close();
    expect(await f.read(), before);
  });

  test('source discovery detects new and removed backend files', () async {
    final f = await Fixture.start();
    final before = sourceFingerprint(f.cwd, ['lib']);
    File(p.join(f.cwd, 'lib')).writeAsStringSync('module');
    expect(sourceFingerprint(f.cwd, ['lib']), isNot(before));
    File(p.join(f.cwd, 'lib')).deleteSync();
    expect(sourceFingerprint(f.cwd, ['lib']), before);
  });

  test('a stuck preparation times out and releases its process', () async {
    final f = await Fixture.start();
    final manager = f.services(f.define(commandTimeout: const Duration(milliseconds: 30), prepare: ['sleep', '1000']));
    await expectLater(manager.ensure(), throwsA(predicate((e) => RegExp('command (failed|timed out)').hasMatch('$e'))));
    expect(manager.status().first['phase'], 'error');
    await manager.close();
    await assertFreePort(f.port);
  });

  test('service evidence catches unapplied edits before a watcher tick and changes on restart', () async {
    final f = await Fixture.start();
    await f.manager.ensure();
    final first = f.manager.status().first;
    expect(first['running'], true);
    expect(first['codeChanged'], false);
    expect((first['source']! as Map)['current'], (first['source']! as Map)['applied']);
    f.write('new revision');
    final stale = f.manager.status().first;
    // The previous process is still healthy.
    expect(stale['phase'], 'ready');
    expect(stale['codeChanged'], true);
    expect((stale['source']! as Map)['current'], isNot((stale['source']! as Map)['applied']));
    expect(stale['generation'], first['generation']);
    await f.manager.ensure();
    final applied = f.manager.status().first;
    expect(applied['codeChanged'], false);
    expect(applied['generation'], isNot(first['generation']));
    await f.manager.close();
    expect(f.manager.status().first['running'], false);
    expect(f.manager.status().first['phase'], 'stopped');
  });

  test('source identity is independent of checkout location', () async {
    final a = await Fixture.start(), b = await Fixture.start();
    expect(sourceFingerprint(a.cwd, ['source']), sourceFingerprint(b.cwd, ['source']));
  });

  test('inspection startup compiles and serves existing data without initial preparation', () async {
    final f = await Fixture.start();
    final manager = f.services(
      f.define(prepare: sh('echo must-not-prepare >&2; exit 1'), compile: sh('echo yes > compiled')),
      prepareOnStart: false,
    );
    await manager.ensure();
    expect((await f.read())['value'], 'one');
    expect(File(p.join(f.cwd, 'compiled')).readAsStringSync().trim(), 'yes');
  });

  test('service environment excludes ambient authority and protects supervisor identity', () {
    final env = serviceEnvironment(
      directory: '/private/service',
      environment: {'APP_SETTING': 'declared'},
      ownership: {'MANA_RESOURCE_RUN': 'owned'},
      inherited: {
        'PATH': '/usr/bin',
        'DATABASE_URL': 'external',
        'RESEND_API_KEY': 'external',
        'NODE_OPTIONS': 'external',
        'DOCKER_HOST': 'external',
        'HOME': '/real-home',
        'MANA_RESOURCE_RUN': 'foreign',
      },
    );
    expect(env, {
      'PATH': '/usr/bin',
      'LANG': 'C.UTF-8',
      'APP_SETTING': 'declared',
      'HOME': '/private/service',
      'TMPDIR': '/private/service/tmp',
      'MANA_RESOURCE_RUN': 'owned',
    });
    for (final key in ['HOME', 'TMPDIR', 'MANA_RESOURCE_RUN']) {
      expect(
        () => serviceEnvironment(directory: '/private', environment: {key: 'foreign'}),
        throwing('cannot override'),
      );
    }
  });

  test('actual child receives only declared settings and owned lifecycle labels', () async {
    final f = await Fixture.start();
    final manager = f.services(f.define(environment: {'APP_SETTING': 'declared'}), lifecycle: FakeLifecycle());
    await manager.ensure();
    final value = await f.read();
    expect(value['leaked'], false);
    expect(value['setting'], 'declared');
    expect(value['home'], p.join(f.cwd, 'services/test'));
    expect(value['tmp'], p.join(f.cwd, 'services/test/tmp'));
    expect(value['run'], 'owned-run');
  });

  test('a service writing to stdout and stderr together keeps both in its log', () async {
    final f = await Fixture.start();
    final noisy = f.services(
      f.define(prepare: sh('for i in 1 2 3 4 5 6 7 8; do echo out\$i; echo err\$i >&2; done; echo once >> prepared')),
    );
    await noisy.ensure();
    final log = File(p.join(f.cwd, 'test.log')).readAsStringSync();
    expect(log, allOf(contains('out8'), contains('err8')));
  });

  test('malformed service declarations are rejected before launch', () async {
    final f = await Fixture.start();
    ServiceDefinition copy({
      int? port,
      List<String>? serve,
      Map<String, String>? environment,
      List<String>? watch,
      String? name,
    }) => ServiceDefinition(
      name: name ?? 'test',
      cwd: f.cwd,
      port: port ?? f.port,
      ready: f.definition.ready,
      serve: serve ?? f.definition.serve,
      environment: environment ?? const {},
      watch: watch ?? const [],
    );
    for (final bad in [
      copy(port: 0),
      copy(serve: const []),
      copy(environment: {'HOME': 'x'}),
      copy(watch: const ['']),
    ]) {
      expect(() => validateServices([bad]), throwsA(anything));
    }
    expect(() => validateServices([copy(), copy(name: 'another')]), throwing('duplicate port'));
  });
}
