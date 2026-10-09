import 'dart:convert';
import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

({String root, String app}) fixture() {
  final root = temporary('moments-cli-');
  final app = p.join(root, 'app');
  Directory(p.join(app, 'moments')).createSync(recursive: true);
  Directory(p.join(app, 'lib/nested')).createSync(recursive: true);
  writeJson(p.join(root, '.moments.json'), {'project': 'app'});
  File(p.join(app, 'lib/view.dart')).writeAsStringSync('source');
  writeJson(p.join(app, 'moments/manifest.json'), {
    'watch': ['lib/view.dart'],
    'moments': {
      'inbox': {
        'checks': [
          {'name': 'restored', 'kind': 'restored', 'field': 'filter', 'equals': 'reservation'},
          {'name': 'unread', 'kind': 'backend_equals', 'field': 'allUnread', 'equals': true, 'match': 'ids'},
        ],
      },
    },
  });
  return (root: root, app: app);
}

CliOptions options(String command, {bool local = false, bool full = false, bool fresh = false, String? name}) =>
    CliOptions()
      ..command = command
      ..local = local
      ..full = full
      ..fresh = fresh
      ..name = name;

void runtimeFile(String app, int port, String token) =>
    writeJson(p.join(app, 'moments/.backend/.runtime.json'), {'url': 'http://127.0.0.1:$port', 'token': token});

void main() {
  setUpAll(compileCli);

  test('finds repo config and nested app, with an explicit override independent of current directory', () {
    final (:root, :app) = fixture();
    expect(findProject(root, null), app);
    expect(findProject(p.join(app, 'lib/nested'), null), app);
    expect(findProject(root, 'app'), app);
    expect(() => findProject(temporary(), null), throwsA(predicate((e) => '$e'.contains('No Moments project'))));
    File(p.join(root, '.moments.json')).writeAsStringSync('{}');
    expect(() => findProject(root, null), throwsA(predicate((e) => '$e'.contains('must declare project'))));
  });

  test('invalid flags cannot silently become plain refreshes or wrong commands', () {
    for (final args in [
      ['refresh', '--chek'],
      ['check'],
      ['status', '--check'],
      ['refresh', 'other'],
      ['refresh', '--project'],
      ['up', 'inbox', '--json'],
      ['check', 'inbox', '--fresh'],
      ['refresh', '--fresh'],
      ['up', 'inbox', '--fresh', '--retry-preparation'],
      ['inspect', '--fresh'],
      ['status', '--fresh'],
      ['list', '--fresh'],
      ['sync', '--fresh'],
      ['open', '--fresh'],
      ['refresh', '--full'],
      ['profile', 'inbox', '--fresh'],
      ['profile', 'inbox', '--session', 'somewhere'],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
    expect(parseArgs(['refresh', '--check', '--json']).check, isTrue);
    expect(parseArgs(['inspect', '--full', '--json']).full, isTrue);
    expect(parseArgs(['open', 'inbox', '--fresh', '--json']).fresh, isTrue);
    expect(parseArgs(['up', 'inbox', '--fresh']).fresh, isTrue);
    expect(parseArgs(['profile', 'inbox', '--json']).command, 'profile');
  });

  test('human output distinguishes request, observation and verified result', () {
    expect(formatResult({'phase': 'compiling'}, options('refresh')), contains('criteria not run'));
    expect(
      formatResult({
        'phase': 'ready',
        'target': {'requested': 'linux', 'connected': 'linux'},
      }, options('status')),
      contains('Device: linux'),
    );
    expect(
      formatResult({
        'phase': 'starting',
        'target': {'requested': 'linux', 'connected': null},
      }, options('status')),
      contains('waiting for Flutter'),
    );
    expect(
      formatResult({
        'status': 'failed',
        'checks': <Object?>[],
        'stage': 'compile',
        'refresh': {'mode': 'started'},
      }, options('refresh')),
      contains('Criteria not run'),
    );
    expect(
      formatResult({
        'moment': {'name': 'inbox'},
        'screen': {'status': 'last-reported'},
        'backend': {'status': 'ready'},
      }, options('inspect')),
      contains('inspecting does not run criteria'),
    );
  });

  test('help runs without a project; JSON usage errors contain no prose', () async {
    final (:root, app: _) = fixture();
    final help = await moments(['--help'], cwd: temporary());
    expect(help.code, 0);
    expect(help.stdout, contains('refresh --check'));
    final bad = await moments(['refresh', '--unknown', '--json'], cwd: root);
    expect(bad.code, 2);
    expect(bad.stderr, '');
    expect((jsonDecode(bad.stdout) as Map)['status'], 'unavailable');
  });

  test('missing runtime returns structured unavailable and exit 2', () async {
    final (:root, app: _) = fixture();
    final result = await moments(['check', 'inbox', '--json'], cwd: root);
    expect(result.code, 2);
    expect((jsonDecode(result.stdout) as Map)['status'], 'unavailable');
    expect(result.stderr, '');
  });

  for (final changed in [false, true]) {
    test(
      changed
          ? 'CLI rejects a declaration edited during inspection'
          : 'CLI compact/full inspection stays read-only and opt-in full retains raw context',
      () async {
        final (:root, :app) = fixture();
        final path = p.join(app, 'moments/manifest.json');
        final projection = {'route': '/inbox', 'filter': 'reservation', 'ids': 'one'};
        final manifest = {
          'version': 2,
          'watch': ['lib/view.dart', 'lib/other.dart'],
          'screens': {
            '/inbox': {
              'watch': ['lib/view.dart'],
            },
          },
          'moments': {
            'inbox': {
              'projection': projection,
              'checks': [
                {'name': 'unread', 'kind': 'backend_equals', 'field': 'allUnread', 'equals': true, 'match': 'ids'},
              ],
            },
          },
        };
        writeJson(path, manifest);
        final sessionFile = p.join(app, 'moments/.session.json');
        File(sessionFile).writeAsStringSync('unchanged session');
        final full = {
          'version': 1,
          'project': app,
          'moment': {'name': 'inbox', 'savedProjection': projection},
          'screen': {
            'status': 'last-reported',
            'liveness': 'not-probed',
            'lastReported': {'projection': projection, 'ageMs': 42, 'matchesRevision': true},
          },
          'backend': {
            'status': 'ready',
            'projection': {'ids': 'one', 'allUnread': true, 'unneeded': 'extra data'},
          },
          'sources': {'declaration': path, 'watched': manifest['watch']},
          'catalog': [
            {'name': 'inbox'},
            {'name': 'other'},
          ],
          'editing': {'properties': <String, Object?>{}},
        };
        final requests = <String>[];
        final api = await serve((request) async {
          requests.add('${request.method} ${request.uri}');
          if (changed) writeJson(path, {...manifest, 'changed': true});
          await replyJson(request, full);
        });
        runtimeFile(app, api.port, 'test-token');
        final compact = await moments(['inspect', '--json'], cwd: root);
        final value = jsonDecode(compact.stdout) as Map;
        expect(compact.code, changed ? 2 : 0);
        if (changed) {
          expect(value['reason'], contains('declaration changed'));
        } else {
          expect(value['view'], 'active-moment');
          expect((value['sources'] as Map)['watched'], ['lib/view.dart']);
          expect((((value['criteria'] as Map)['items'] as List).first as Map)['name'], 'unread');
          expect((value['criteria'] as Map)['executed'], isFalse);
          expect(value.containsKey('catalog'), isFalse);
          expect(((value['screen'] as Map)['lastReported'] as Map).containsKey('projection'), isFalse);
          final expanded = await moments(['inspect', '--full', '--json'], cwd: root);
          expect(expanded.code, 0);
          expect(jsonDecode(expanded.stdout), full);
        }
        expect(requests.every((r) => r == 'GET /moments/inspect'), isTrue);
        expect(File(sessionFile).readAsStringSync(), 'unchanged session');
      },
    );
  }

  for (final (expected, unread) in [('passed', true), ('failed', false), ('unavailable', null)]) {
    test('actual CLI preserves $expected, report and exit code', () async {
      final (:root, :app) = fixture();
      final projection = {'route': '/inbox', 'filter': 'reservation', 'ids': 'one', 'scrollOffset': 10};
      var revision = 0;
      final supervisor = {
        'phase': 'ready',
        'services': [
          {
            'name': 'backend',
            'phase': 'ready',
            'running': true,
            'codeChanged': false,
            'generation': '00000000-0000-4000-8000-000000000001',
            'source': {'current': 'a' * 64, 'applied': 'a' * 64},
          },
        ],
      };
      final api = await serve((request) async {
        expect(request.headers.value('authorization'), 'Bearer test-only-token');
        await request.drain<void>();
        switch (request.uri.path) {
          case '/dev/status':
            return replyJson(request, supervisor);
          case '/moments/open':
            revision++;
            return replyJson(request, {
              'revision': revision,
              'state': {'name': 'inbox', 'projection': projection},
            });
          case '/moments/look':
            return replyJson(request, {
              'revision': revision,
              'state': {'name': 'inbox', 'projection': projection},
              'codeChanged': false,
              'observed': {'revision': revision, 'client': 'flutter', 'projection': projection},
            });
          case '/moments/inspect':
            return replyJson(request, {
              'supervisor': supervisor,
              'moment': {'revision': revision, 'codeChanged': false},
              'screen': {
                'lastReported': {'matchesRevision': true, 'projection': projection},
              },
              'backend': unread == null
                  ? {'status': 'unavailable'}
                  : {
                      'status': 'ready',
                      'projection': {'ids': 'one', 'allUnread': unread},
                    },
            });
        }
        return replyJson(request, {}, status: 404);
      });
      runtimeFile(app, api.port, 'test-only-token');
      final result = await moments(['check', 'inbox', '--json'], cwd: p.join(app, 'lib/nested'));
      expect(result.code, {'passed': 0, 'failed': 1, 'unavailable': 2}[expected]);
      final value = jsonDecode(result.stdout) as Map;
      expect(value['status'], expected);
      expect((value['report'] as String).startsWith(p.join(app, 'moments/.proofs')), isTrue);
      expect(result.stderr, '');
      expect(result.stdout, isNot(contains('test-only-token')));
      if (expected == 'passed') {
        final human = await moments(['check', 'inbox'], cwd: root);
        expect(human.code, 0);
        expect(human.stdout, contains('PASSED · inbox'));
        expect(human.stdout, contains('Report:'));
      }
    });
  }

  test('short CLI fresh replaces only the selected saved UI and rejects a stale capture', () async {
    final (:root, :app) = fixture();
    final initial = {'route': '/inbox', 'filter': 'all', 'draft': ''};
    final manifestFile = p.join(app, 'moments/manifest.json');
    writeJson(manifestFile, {
      'version': 1,
      'watch': ['lib/view.dart'],
      'properties': {
        'route': {
          'enum': ['/inbox'],
        },
        'filter': {
          'enum': ['all', 'reservation'],
        },
        'draft': {'type': 'string', 'maxLength': 100},
      },
      'moments': {
        'inbox': {'projection': initial},
        'other': {'projection': initial},
      },
    });
    final bridge = await Bridge.start(
      project: app,
      port: 0,
      momentsOptions: MomentsOptions(manifestFile: manifestFile, initialName: 'inbox'),
    );
    addTearDown(bridge.close);
    Future<({int code, Map<String, Object?> value})> request(String op, [Map<String, Object?>? data]) =>
        call(bridge.url, bridge.token, '/moments/$op', data);
    final sessionFile = p.join(app, 'moments/.session.json');
    Map<String, Object?> session() => (readJson(sessionFile)! as Map).cast();
    final first = await request('changes?since=&client=cli-fixture');
    final edited = {...initial, 'filter': 'reservation', 'draft': 'Keep this inbox draft'};
    final oldCapture = {
      'client': 'cli-fixture',
      'revision': first.value['revision'],
      'sequence': 1,
      'projection': edited,
    };
    expect((await request('capture', oldCapture)).code, 200);
    final other = await request('open', {'name': 'other'});
    expect(
      (await request('capture', {
        ...oldCapture,
        'revision': other.value['revision'],
        'projection': {...initial, 'draft': 'Keep the other Moment too'},
      })).code,
      200,
    );
    final otherSaved = (session()['states']! as Map)['other'];
    Future<Run> open(List<String> args) async {
      final current = await request('look');
      final changed = request('changes?since=${current.value['revision']}&client=cli-fixture');
      final running = moments(args, cwd: p.join(app, 'lib/nested'));
      final next = await changed;
      expect(next.code, 200);
      expect(
        (await request('observe', {
          'client': 'cli-fixture',
          'revision': next.value['revision'],
          'projection': (next.value['state']! as Map)['projection'],
        })).code,
        200,
      );
      final result = await running;
      expect(result.code, 0, reason: result.stdout);
      expect(result.stderr, '');
      return result;
    }

    runtimeFile(app, Uri.parse(bridge.url).port, bridge.token);
    final resumed = jsonDecode((await open(['open', 'inbox', '--json'])).stdout) as Map;
    expect((resumed['state'] as Map)['projection'], edited);
    expect((resumed['observed'] as Map)['projection'], edited);
    final fresh = jsonDecode((await open(['open', 'inbox', '--fresh', '--json'])).stdout) as Map;
    expect((fresh['state'] as Map)['projection'], initial);
    expect((fresh['observed'] as Map)['projection'], initial);
    expect(fresh['revision'], isNot(resumed['revision']));
    expect(((session()['states']! as Map)['inbox'] as Map)['projection'], initial);
    expect((session()['states']! as Map)['other'], otherSaved);
    final savedAfterFresh = File(sessionFile).readAsStringSync();
    expect((await request('capture', {...oldCapture, 'revision': resumed['revision'], 'sequence': 99})).code, 409);
    expect(File(sessionFile).readAsStringSync(), savedAfterFresh);
    final invalid = await moments(['refresh', '--fresh', '--json'], cwd: root);
    expect(invalid.code, 2);
    expect((jsonDecode(invalid.stdout) as Map)['reason'], contains('only applies to open'));
    expect(File(sessionFile).readAsStringSync(), savedAfterFresh);
    final missing = await moments(['open', 'missing', '--fresh', '--json'], cwd: root);
    expect(missing.code, 2);
    expect(File(sessionFile).readAsStringSync(), savedAfterFresh);
    final human = await open(['open', 'inbox', '--fresh']);
    expect(human.stdout, contains('initial UI recipe'));
    expect(human.stdout, contains('Resume confirmed'));
    final returned = jsonDecode((await open(['open', 'other', '--json'])).stdout) as Map;
    expect(returned['state'], otherSaved);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('sync bootstraps a consumer before its first generated manifest exists', () async {
    final (root: _, :app) = fixture();
    File(p.join(app, 'moments/manifest.json')).deleteSync();
    writeJson(p.join(app, 'moments/backend.json'), {
      'version': 1,
      'sync': {
        'command': ['sh', '-c', '''printf '{"version":2,"moments":{}}' > moments/manifest.json'''],
      },
    });
    expect(findProject(p.join(app, 'lib/nested'), null), app);
    final result = await moments(['sync'], cwd: app);
    expect(result.code, 0, reason: result.stderr + result.stdout);
    expect(readJson(p.join(app, 'moments/manifest.json')), {'version': 2, 'moments': <String, Object?>{}});
  });

  test('device selection is explicit for startup and cannot be ignored by checks', () {
    expect(parseArgs(['up', 'inbox', '--device', 'linux']).device, 'linux');
    expect(parseArgs(['up', 'inbox', '--device', 'web-server']).device, 'web-server');
    expect(parseArgs(['up', 'inbox', '--device', 'android:emulator-5554']).device, 'android:emulator-5554');
    for (final device in ['android:', 'android:-d', 'android:emulator-5554 other']) {
      expect(() => parseArgs(['up', 'inbox', '--device', device]), throwsA(anything));
    }
    for (final args in [
      ['up', 'inbox', '--device'],
      ['up', 'inbox', '--device', 'android'],
      ['check', 'inbox', '--device', 'linux'],
      ['refresh', '--device', 'linux'],
      ['open', 'inbox', '--device', 'linux'],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
  });

  test('restart is an explicit refresh option, never an implicit recipe replay', () {
    expect(parseArgs(['refresh', '--restart', '--check']).restart, isTrue);
    expect(
      () => parseArgs(['run', 'inbox', '--restart']),
      throwsA(predicate((e) => '$e'.contains('only applies to refresh'))),
    );
  });

  test('down is explicit instance shutdown and does not accept journey replay options', () {
    expect(parseArgs(['down', '--json']).command, 'down');
    expect(() => parseArgs(['down', '--fresh']), throwsA(predicate((e) => '$e'.contains('fresh'))));
    expect(() => parseArgs(['down', '--restart']), throwsA(predicate((e) => '$e'.contains('restart'))));
    expect(
      formatResult({'status': 'stopped', 'mode': 'recovered', 'preserved': true}, options('down')),
      contains('kept'),
    );
  });

  test('status distinguishes durable intent from a confirmed effect and explains recovery', () {
    final text = formatResult({
      'phase': 'idle',
      'journey': {
        'name': 'inbox',
        'phase': 'attention',
        'lastOperation': {'operation': 'tap', 'target': 'read-one'},
      },
    }, options('status'));
    expect(text, contains('Last recorded intent: tap · read-one'));
    expect(text, contains('check the effect on the backend'));
    expect(text, contains('moments inspect'));
    expect(text, contains('moments recover'));
  });

  test('local status and explicit data discard have unambiguous CLI scope', () {
    expect(parseArgs(['status', '--local', '--json']).local, isTrue);
    expect(parseArgs(['reset', '--discard-data']).discardData, isTrue);
    expect(() => parseArgs(['reset']), throwsA(predicate((e) => '$e'.contains('discard-data'))));
    expect(
      () => parseArgs(['down', '--discard-data']),
      throwsA(predicate((e) => '$e'.contains('only applies to reset'))),
    );
    expect(() => parseArgs(['inspect', '--local']), throwsA(predicate((e) => '$e'.contains('only applies to status'))));
  });
}
