import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson, processIdentity, uuidV4;
import 'package:moments/src/cli.dart';
import 'package:moments/src/lifecycle.dart';
import 'package:moments/src/managed.dart';
import 'package:moments/src/manifest.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

void write(String file, Object? value) {
  File(file).writeAsStringSync('${jsonEncode(value)}\n');
  Process.runSync('chmod', ['600', file]);
}

void privateDirectory(String dir) {
  Directory(dir).createSync(recursive: true);
  Process.runSync('chmod', ['700', dir]);
}

Map<String, Object?> get supervisor => identityJson(processIdentity(pid)!);

final class Fixture {
  Fixture._(this.project, this.directory, this.id, this.actor, this.run, this.files, this.world, this.requests);
  final String project, directory, id, actor, run;
  final Map<String, String> files;
  final Map<String, Object?> world;
  final List<({String path, String method})> requests;
  final name = 'session';
  void Function() duringRequest = () {};

  static Future<Fixture> create({String actual = 'authenticated', bool criteria = true}) async {
    final project = temporary('mana-managed-check-'), id = uuidV4();
    final directory = p.join(project, 'moments/.proofs/materializations', uuidV4()),
        run = p.join(directory, 'runs', uuidV4());
    final actor = p.join(run, 'instances', id), layer = p.join(actor, 'actor');
    for (final dir in [
      p.join(project, 'moments'),
      p.join(project, 'moments/.proofs'),
      p.dirname(directory),
      directory,
      p.join(directory, 'runs'),
      run,
      p.join(run, 'instances'),
      actor,
      layer,
    ]) {
      privateDirectory(dir);
    }
    privateDirectory(p.join(project, 'moments/.backend'));
    final manifestFile = p.join(project, 'moments/manifest.json');
    write(manifestFile, {
      'version': 3,
      'protocol': protocol,
      'watch': <Object>[],
      'properties': {
        'route': {
          'enum': ['/'],
        },
        'phase': {'default': 'anonymous', 'restore': false, 'type': 'string'},
      },
      'moments': {
        'session': {
          'projection': {'route': '/'},
          'checks': [
            if (criteria) {'name': 'authenticated', 'kind': 'ui_equals', 'field': 'phase', 'equals': 'authenticated'},
          ],
        },
      },
    });
    final manifest = readManifest(manifestFile)['recipeHash'], code = 'a' * 64, workspace = workspaceIdentity(project);
    final files = {
      'session': p.join(directory, 'session.json'),
      'run': p.join(run, 'run.json'),
      'marker': p.join(project, 'moments/.backend/materialization.json'),
      'actor': p.join(actor, 'instance.json'),
      'runtime': p.join(layer, '.runtime.json'),
    };
    write(files['session']!, {
      'version': 2,
      'workspace': workspace,
      'supervisor': supervisor,
      'name': 'session',
      'phase': 'ready',
      'run': run,
    });
    write(files['marker']!, {'version': 1, 'workspace': workspace, 'directory': directory, 'supervisor': supervisor});
    write(files['run']!, {
      'version': 1,
      'runId': p.basename(run),
      'workspace': workspace,
      'supervisor': supervisor,
      'manifest': manifest,
      'code': code,
      'runtime': 'ash-flutter-local',
      'layers': [
        {'name': 'actor', 'type': 'flutter-actor'},
      ],
    });
    final world = <String, Object?>{
      'version': 1,
      'id': id,
      'name': 'session',
      'materializedMoment': 'session',
      'phase': 'ready',
      'manifest': manifest,
      'code': code,
      'layers': {
        'actor': {'dir': layer, 'phase': 'ready'},
      },
    };
    write(files['actor']!, world);
    final projection = {'route': '/', 'phase': actual}, revision = uuidV4();
    final requests = <({String path, String method})>[];
    final look = {
      'revision': revision,
      'state': {
        'name': 'session',
        'projection': {'route': '/'},
      },
      'observed': {'revision': revision, 'client': 'fixture-runtime', 'projection': projection},
      'materialization': {'instanceId': id, 'moment': 'session', 'from': 'session', 'manifest': manifest},
      'codeChanged': false,
    };
    late Fixture fixture;
    final server = await serve((request) async {
      requests.add((path: request.uri.toString(), method: request.method));
      expect(request.headers.value('authorization'), 'Bearer ${'b' * 48}');
      fixture.duringRequest();
      await replyJson(
        request,
        request.uri.path == '/moments/look'
            ? look
            : {
                'moment': {'revision': revision, 'codeChanged': false},
                'screen': {
                  'lastReported': {'matchesRevision': true, 'projection': projection},
                },
              },
      );
    });
    write(files['runtime']!, {'url': 'http://127.0.0.1:${server.port}', 'token': 'b' * 48, 'pid': pid});
    return fixture = Fixture._(project, directory, id, actor, run, files, world, requests);
  }

  void update(String key, Map<String, Object?> patch) => write(files[key]!, {
    ...(jsonDecode(File(files[key]!).readAsStringSync()) as Map).cast<String, Object?>(),
    ...patch,
  });

  Future<Map<String, Object?>> check([String? actorId]) =>
      checkManagedActor(project, directory: directory, name: name, actorId: actorId);
}

void main() {
  test('CLI requires a named session check and a scoped actor selector', () {
    final id = uuidV4();
    expect(parseArgs(['check', 'session', '--session', 'private', '--actor', id]).actorId, id);
    for (final args in [
      ['check', 'session', '--actor', id],
      ['recover', '--session', 'private', '--actor', id],
      ['check', 'session', '--session', 'private', '--actor', 'bad'],
      ['check', 'session', '--session', 'private', '--actor', id, '--actor', id],
      ['check', 'session', '--session', 'private', '--run', 'run'],
      ['check', 'session', '--session', 'private', '--fresh'],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
  });

  test('live checks use observation requests, preserve the actor, and retain pass/fail/unavailable exits', () async {
    for (final (actual, criteria, status, code) in [
      ('authenticated', true, 'passed', 0),
      ('anonymous', true, 'failed', 1),
      ('authenticated', false, 'unavailable', 2),
    ]) {
      final f = await Fixture.create(actual: actual, criteria: criteria);
      final before = File(f.files['actor']!).readAsStringSync();
      final result = await f.check();
      expect(result['status'], status);
      expect(result['exitCode'], code);
      expect(result['actorId'], f.id);
      expect((readJson(result['report']! as String)! as Map)['operation'], 'materialized-check');
      expect(
        f.requests.every((r) => r.method == 'GET' && const ['/moments/look', '/moments/inspect'].contains(r.path)),
        isTrue,
      );
      expect(File(f.files['actor']!).readAsStringSync(), before);
      final connection = connectManagedActor(f.project, directory: f.directory, name: f.name);
      final count = f.requests.length;
      await expectLater(connection.request('/journey/tap', {'target': 'write'}), throwing('only permits observation'));
      expect(f.requests, hasLength(count));
    }
  });

  test('foreign, ended, changed and non-loopback identities fail before any HTTP request', () async {
    for (final mutate in <void Function(Fixture f)>[
      (f) => f.update('session', {'phase': 'closed'}),
      (f) => f.update('session', {'workspace': 'c' * 64}),
      (f) => f.update('session', {
        'supervisor': {...supervisor, 'start': '0'},
      }),
      (f) => f.update('marker', {'directory': p.join(f.project, 'foreign')}),
      (f) => f.update('run', {'manifest': 'd' * 64}),
      (f) => f.update('actor', {'code': 'e' * 64}),
      (f) => f.update('runtime', {'url': 'http://example.invalid:80'}),
      (f) => f.update('runtime', {'pid': pid + 1}),
      (f) {
        final runtime = f.files['runtime']!, target = '$runtime.saved';
        File(runtime).renameSync(target);
        Link(runtime).createSync(target);
      },
    ]) {
      final f = await Fixture.create();
      mutate(f);
      expect(() => connectManagedActor(f.project, directory: f.directory, name: f.name), throwsA(anything));
      expect(f.requests, isEmpty);
    }
  });

  test('multiple actors require selection and the returned bridge must identify the selected actor', () async {
    final f = await Fixture.create(), other = uuidV4();
    final dir = p.join(f.run, 'instances', other), layer = p.join(dir, 'actor');
    privateDirectory(dir);
    privateDirectory(layer);
    write(p.join(dir, 'instance.json'), {
      ...f.world,
      'id': other,
      'layers': {
        'actor': {'dir': layer, 'phase': 'ready'},
      },
    });
    write(p.join(layer, '.runtime.json'), readJson(f.files['runtime']!));
    expect(() => connectManagedActor(f.project, directory: f.directory, name: f.name), throwing('Multiple actors'));
    expect(
      () => connectManagedActor(f.project, directory: f.directory, name: f.name, actorId: uuidV4()),
      throwing('does not belong'),
    );
    expect((await f.check(f.id))['status'], 'passed');
    expect((await f.check(other))['status'], 'unavailable');
  });

  test('a session closing during an observation cannot leave a passed receipt', () async {
    final f = await Fixture.create();
    f.duringRequest = () => f.update('session', {'phase': 'closing'});
    final result = await f.check();
    expect(result['status'], 'unavailable');
    expect(result['exitCode'], 2);
    expect((readJson(result['report']! as String)! as Map)['status'], 'unavailable');
  });

  test('native checks require matching live app/transport ownership and notice closure during observation', () async {
    final f = await Fixture.create();
    const device = 'emulator-5554';
    final boot = uuidV4();
    f.update('run', {'runtime': 'ash-flutter-android'});
    f.update('session', {'device': 'android:$device'});
    expect(() => connectManagedActor(f.project, directory: f.directory, name: f.name), throwsA(anything));
    expect(f.requests, isEmpty);
    final appFile = p.join(f.actor, 'android-app.json'), transportFile = p.join(f.actor, 'transport.json');
    write(appFile, {
      'version': 1,
      'owner': f.id,
      'device': device,
      'boot': boot,
      'supervisor': supervisor,
      'phase': 'running',
    });
    write(transportFile, {
      'version': 1,
      'owner': f.id,
      'device': device,
      'boot': boot,
      'supervisor': supervisor,
      'phase': 'ready',
    });
    expect((await f.check())['status'], 'passed');
    f.update('session', {'device': 'android:other-device'});
    expect(
      () => connectManagedActor(f.project, directory: f.directory, name: f.name),
      throwing('ownership is not ready'),
    );
    f.update('session', {'device': 'android:$device'});
    f.duringRequest = () => write(appFile, {
      'version': 1,
      'owner': f.id,
      'device': device,
      'boot': boot,
      'supervisor': supervisor,
      'phase': 'stopped',
    });
    expect((await f.check())['status'], 'unavailable');
  });
}
