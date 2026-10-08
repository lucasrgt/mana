import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/backend_recipes.dart';
import 'package:moments/src/bridge.dart';
import 'package:moments/src/check.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/inspect.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

final class Dev implements Development {
  Dev(this._inspect);
  final Future<Map<String, Object?>> Function() _inspect;
  @override
  Map<String, Object?> status() => {
    'phase': 'idle',
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
  @override
  Future<Map<String, Object?>> Function()? get inspect => _inspect;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => null;
  @override
  Future<void> Function()? get stop => null;
  @override
  Renewal? get renewal => null;
}

final class Fixture {
  Fixture._(this.project, this.manifest, this.recipes, this.calls);
  final String project;
  final Map<String, Object?> manifest;
  final BackendRecipes recipes;
  final Map<String, Object?> calls;
  late final Bridge bridge;

  String get manifestFile => p.join(project, 'moments/manifest.json');
  void save() => writeJson(manifestFile, manifest);
  String disk() => File(p.join(project, 'moments/.session.json')).readAsStringSync();

  static Future<Fixture> start({
    Future<void> Function()? prepare,
    void Function()? available,
    bool configured = true,
  }) async {
    final project = temporary('backend-recipes-');
    for (final dir in ['moments', 'live-ui', 'lib']) {
      Directory(p.join(project, dir)).createSync();
    }
    File(p.join(project, 'live-ui/schema.json')).writeAsStringSync('{}');
    File(p.join(project, 'live-ui/overrides.json')).writeAsStringSync('{"version":1,"values":{}}');
    File(p.join(project, 'lib/view.dart')).writeAsStringSync('source');
    final initial = {'route': '/inbox', 'filter': 'all', 'ids': 'one'};
    final scene = {
      'projection': initial,
      'backend': {'recipe': 'inbox'},
      'checks': [
        {'name': 'read-state', 'kind': 'backend_equals', 'field': 'allUnread', 'equals': true, 'match': 'ids'},
      ],
    };
    final manifest = <String, Object?>{
      'version': 1,
      'watch': ['lib/view.dart'],
      'properties': {
        'route': {
          'enum': ['/inbox'],
        },
        'filter': {
          'enum': ['all', 'saved'],
        },
        'ids': {'type': 'string', 'maxLength': 100},
      },
      'moments': {
        'plain': {'projection': initial},
        'chosen': scene,
        'unknown': {
          ...scene,
          'backend': {'recipe': 'not-registered'},
        },
        'invalid': {
          ...scene,
          'backend': {'recipe': '../script'},
        },
      },
    };
    final calls = <String, Object?>{'prepare': 0, 'inspect': 0, 'acquired': 0, 'released': 0};
    void bump(String key) => calls[key] = (calls[key]! as int) + 1;
    final instance = {
      'account': {'password': 'never-export'},
    };
    final recipes = BackendRecipes(
      manifestFile: p.join(project, 'moments/manifest.json'),
      instance: () => instance,
      assertAvailable: () async => available?.call(),
      acquire: () {
        bump('acquired');
        return () => bump('released');
      },
      recipes: {
        'inbox': RecipeAdapter(
          prepare: (value) async {
            expect(value, same(instance));
            bump('prepare');
            await prepare?.call();
            return null;
          },
          inspect: (_, context) async {
            bump('inspect');
            calls['context'] = context;
            return {
              'status': 'ready',
              'projection': {'ids': 'one', 'allUnread': false},
            };
          },
        ),
      },
    );
    final fixture = Fixture._(project, manifest, recipes, calls)..save();
    late Bridge bridge;
    bridge = await Bridge.start(
      directory: p.join(project, 'live-ui'),
      port: 0,
      momentsOptions: MomentsOptions(
        manifestFile: fixture.manifestFile,
        initialName: 'plain',
        prepare: configured ? recipes.prepare : null,
      ),
      development: Dev(() => recipes.inspect((bridge.moments!.inspect()['state']! as Map)['name']! as String)),
    );
    fixture.bridge = bridge;
    addTearDown(bridge.close);
    return fixture;
  }

  Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
    final (:code, :value) = await call(bridge.url, bridge.token, path, data);
    return {'status': code, ...value};
  }
}

int count(Fixture f, String key) => f.calls[key]! as int;

void main() {
  test('query context is copied for the observer, never treated as backend evidence', () async {
    final f = await Fixture.start();
    final context = {
      'projection': {'pageOffset': 100, 'ids': 'forged', 'allUnread': true},
    };
    final result = await f.recipes.inspect('chosen', context: context);
    expect(f.calls['context'], context);
    ((f.calls['context']! as Map)['projection'] as Map)['pageOffset'] = 200;
    expect(context['projection']!['pageOffset'], 100);
    expect((result['projection']! as Map)['ids'], 'one');
    expect((result['projection']! as Map)['allUnread'], false);
    expect(count(f, 'prepare'), 0);
  });

  test('declared backend preparation finishes before opening; inspection and checks never prepare', () async {
    final f = await Fixture.start();
    final connected = await f.request('/moments/changes?since=&client=ui');
    final before = f.disk();
    await f.request('/moments/capture', {
      'client': 'ui',
      'revision': connected['revision'],
      'sequence': 1,
      'projection': {
        ...((connected['state']! as Map)['projection']! as Map).cast<String, Object?>(),
        'filter': 'saved',
      },
    });
    final oldPlain = ((jsonDecode(f.disk()) as Map)['states'] as Map)['plain'];
    final opened = await f.request('/moments/open', {'name': 'chosen'});
    expect(opened['status'], 200);
    expect(count(f, 'prepare'), 1);
    expect(((jsonDecode(f.disk()) as Map)['states'] as Map)['plain'], oldPlain);
    expect(f.disk(), isNot(before));
    final inspection = await f.request('/moments/inspect');
    expect((inspection['backend']! as Map)['recipe'], 'inbox');
    expect(count(f, 'prepare'), 1);
    expect(((inspection['moment']! as Map)['backend']! as Map)['recipe'], 'inbox');
    expect(jsonEncode(inspection).contains('never-export'), isFalse);
    final result = await checkMoment(
      project: f.project,
      name: 'chosen',
      request: (path, [data]) async {
        final value = await f.request(path, data);
        if (path == '/moments/open') {
          await f.request('/moments/observe', {
            'client': 'ui',
            'revision': value['revision'],
            'projection': (value['state']! as Map)['projection'],
          });
        }
        return value;
      },
    );
    // The inspector saw a read notification and never repaired it.
    expect(result['status'], 'failed');
    expect(count(f, 'prepare'), 1);
    expect(count(f, 'acquired'), count(f, 'released'));
  });

  test('preparation failure keeps old UI, releases the lock, and retry is explicit', () async {
    var fails = true;
    final f = await Fixture.start(
      prepare: () async {
        if (fails) throw const MomentsError('data not ready');
      },
    );
    await f.request('/moments/changes?since=&client=ui');
    final before = f.disk();
    expect((await f.request('/moments/open', {'name': 'chosen'}))['status'], 400);
    expect(f.disk(), before);
    expect(count(f, 'prepare'), 1);
    expect(count(f, 'released'), 1);
    fails = false;
    expect((await f.request('/moments/open', {'name': 'chosen'}))['status'], 200);
    expect(count(f, 'prepare'), 2);
  });

  test('unknown recipes, invalid identifiers and unavailable ownership fail before invoking an adapter', () async {
    var owned = true;
    final f = await Fixture.start(
      available: () {
        if (!owned) throw const MomentsError('not owned');
      },
    );
    await f.request('/moments/changes?since=&client=ui');
    final before = f.disk();
    for (final name in ['unknown', 'invalid']) {
      expect((await f.request('/moments/open', {'name': name}))['status'], 400);
    }
    owned = false;
    expect((await f.request('/moments/open', {'name': 'chosen'}))['status'], 400);
    expect(f.disk(), before);
    expect(count(f, 'prepare'), 0);
    expect(count(f, 'acquired'), 0);
  });

  test('declared backend cannot silently open without an executor', () async {
    final f = await Fixture.start(configured: false);
    await f.request('/moments/changes?since=&client=ui');
    final before = f.disk();
    expect((await f.request('/moments/open', {'name': 'chosen'}))['status'], 400);
    expect(f.disk(), before);
  });

  test('preparation excludes competing opens and captures; edited declaration cannot be applied afterward', () async {
    final entered = Completer<void>(), held = Completer<void>();
    final f = await Fixture.start(
      prepare: () async {
        entered.complete();
        await held.future;
      },
    );
    final connected = await f.request('/moments/changes?since=&client=ui');
    final before = f.disk();
    final opening = f.request('/moments/open', {'name': 'chosen'});
    await entered.future;
    expect((await f.request('/moments/open', {'name': 'plain'}))['status'], 400);
    expect((await f.request('/moments/reset', {}))['status'], 400);
    expect(
      (await f.request('/moments/capture', {
        'client': 'ui',
        'revision': connected['revision'],
        'sequence': 1,
        'projection': (connected['state']! as Map)['projection'],
      }))['status'],
      400,
    );
    ((f.manifest['moments']! as Map)['chosen'] as Map)['description'] = 'Edited while preparing';
    f.save();
    held.complete();
    expect((await opening)['status'], 400);
    expect(f.disk(), before);
    expect(count(f, 'acquired'), count(f, 'released'));
  });

  test('prepared launch persists; lost ownership or disk failure preserves the previous instance', () async {
    final f = await Fixture.start();
    var current = <String, Object?>{
      'launch': {
        'projection': {'id': 'old'},
        'account': {'password': 'private'},
      },
    };
    var owned = true, failDisk = false, loseOwnership = false, commits = 0;
    final engine = BackendRecipes(
      manifestFile: f.manifestFile,
      instance: () => current,
      assertAvailable: () async {
        if (!owned) throw const MomentsError('lost ownership');
      },
      commit: (launch, {base, preparedMoment}) async {
        if (failDisk) throw const MomentsError('disk failed');
        current = {...current, 'launch': launch};
        commits++;
      },
      recipes: {
        'inbox': RecipeAdapter(
          prepare: (_) async {
            if (loseOwnership) owned = false;
            return {
              'launch': {
                ...(current['launch']! as Map).cast<String, Object?>(),
                'projection': {'id': 'new'},
              },
            };
          },
          inspect: (_, _) async => {'projection': (current['launch']! as Map)['projection']},
        ),
      },
    );
    await engine.prepare('plain');
    expect(commits, 0);
    await engine.prepare('chosen');
    expect(commits, 1);
    expect(((await engine.inspect('chosen'))['projection']! as Map)['id'], 'new');
    final saved = current;
    failDisk = true;
    await expectLater(engine.prepare('chosen'), throwsA(predicate((e) => '$e'.contains('disk failed'))));
    expect(current, same(saved));
    failDisk = false;
    loseOwnership = true;
    await expectLater(engine.prepare('chosen'), throwsA(predicate((e) => '$e'.contains('lost ownership'))));
    expect(current, same(saved));
    expect(commits, 1);
  });

  test('committed preparation identifies the exact Moment for restart without recipe replay', () async {
    final f = await Fixture.start();
    var current = <String, Object?>{
      'phase': 'ready',
      'launch': {'input': 'previous'},
    };
    var calls = 0;
    final engine = BackendRecipes(
      manifestFile: f.manifestFile,
      instance: () => current,
      assertAvailable: () async {},
      commit: (launch, {base, preparedMoment}) async {
        current = {...current, 'launch': launch, 'preparedMoment': preparedMoment};
      },
      recipes: {
        'inbox': RecipeAdapter(
          prepare: (_) async => {
            'launch': {'input': 'prepared-${++calls}'},
          },
          inspect: (_, _) async => {'status': 'ready'},
        ),
      },
    );
    expect(preparedRecipeMatches(current, 'chosen', {'recipe': 'inbox'}), isFalse);
    await engine.prepare('chosen');
    final durable = (jsonDecode(jsonEncode(current)) as Map).cast<String, Object?>();
    expect(preparedRecipeMatches(durable, 'chosen', {'recipe': 'inbox'}), isTrue);
    await engine.inspect('chosen');
    expect(calls, 1);
    expect(current, durable);
    for (final (instance, name, backend) in [
      (durable, 'plain', {'recipe': 'inbox'}),
      (durable, 'chosen', {'recipe': 'another'}),
      (durable, 'chosen', {'recipe': 'inbox', 'base': 'new-base'}),
      ({...durable, 'launch': null}, 'chosen', {'recipe': 'inbox'}),
      ({...durable, 'phase': 'seeding'}, 'chosen', {'recipe': 'inbox'}),
      (
        {
          ...durable,
          'preparation': {'stage': 'recipe'},
        },
        'chosen',
        {'recipe': 'inbox'},
      ),
    ]) {
      expect(preparedRecipeMatches(instance, name, backend), isFalse, reason: '$name $backend');
    }
  });
}
