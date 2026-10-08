import 'dart:convert';
import 'dart:io';

import 'package:moments/src/backend_recipes.dart';
import 'package:moments/src/check.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/graph.dart';
import 'package:moments/src/http_server.dart' show reply;
import 'package:moments/src/manifest.dart';
import 'package:moments/src/profile.dart';
import 'package:moments/src/protocol.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => RegExp(text).hasMatch('$e'), 'matches "$text"'));

const scenes = {
  'checkout': {'description': 'Checkout'},
  'approved': {'from': 'checkout', 'description': 'Approved'},
  'declined': {'from': 'checkout', 'description': 'Declined'},
};
const map =
    '# Shop\nmoments: 0.1\n\n## checkout\nCheckout\n\n## approved\nfrom: checkout\nApproved\n\n## declined\nfrom: checkout\nDeclined\n';

({String project, String file, Map<String, Object?> manifest}) fixture() {
  final project = temporary('mana-protocol-');
  Directory(p.join(project, 'moments')).createSync();
  Directory(p.join(project, 'lib')).createSync();
  File(p.join(project, 'lib/main.dart')).writeAsStringSync('// source');
  final manifest = <String, Object?>{
    'version': 3,
    'protocol': protocol,
    'watch': ['lib/main.dart'],
    'properties': <String, Object?>{
      'route': {
        'enum': ['/checkout'],
      },
    },
    'moments': <String, Object?>{
      for (final MapEntry(:key, :value) in scenes.entries)
        key: <String, Object?>{
          ...value,
          'checks': <Object?>[],
          'steps': <Object?>[],
          'projection': <String, Object?>{'route': '/checkout'},
          'backend': {'recipe': 'checkout'},
        },
    },
  };
  final file = p.join(project, 'moments/manifest.json');
  writeJson(file, manifest);
  return (project: project, file: file, manifest: manifest);
}

Map<String, Object?> scene(Map<String, Object?> manifest, String name) =>
    ((manifest['moments']! as Map)[name] as Map).cast();

Map<String, Object?> profileReport() => {
  'status': 'passed',
  'durationMs': 15,
  'timings': {'steps': 10, 'verification': 5},
  'steps': <Object?>[],
  'actions': {
    'status': 'observed',
    'overflow': false,
    'receipts': [
      {
        'version': 2,
        'step': 'save',
        'truncated': false,
        'profile': {
          'requestDurationUs': 10000,
          'database': {
            'status': 'observed',
            'queries': 2,
            'totalUs': 6000,
            'queryUs': 5000,
            'queueUs': 1000,
            'decodeUs': 0,
          },
        },
        'actions': [
          {'resource': 'App.Task', 'action': 'save', 'durationUs': 9000},
          {'resource': 'App.Task', 'action': 'validate', 'durationUs': 5000},
        ],
      },
      {
        'version': 2,
        'step': 'save',
        'truncated': false,
        'profile': {
          'requestDurationUs': 8000,
          'database': {'status': 'not-observed'},
        },
        'actions': <Object?>[],
      },
    ],
  },
};

void main() {
  setUpAll(compileCli);

  test(
    'real Ash multi-domain export has the same topology and meaning as the Markdown map',
    () {
      final manifest = readManifest(Platform.environment['MANA_LINEAGE_MANIFEST']!);
      expect(
        momentGraph((manifest['moments']! as Map).cast()),
        graphFromMap(
          '# Payment\nmoments: 0.1\n\n## checkout\nCheckout ready to choose the payment.\n\n'
          '## approved\nfrom: checkout\nPayment approved after checkout.\n\n'
          '## declined\nfrom: checkout\nPayment declined after checkout.\n',
        ),
      );
      expect(manifest['version'], 3);
      expect((manifest['screens']! as Map).keys.toList()..sort(), ['/checkout', '/payment']);
      expect((manifest['moments']! as Map).values.every((scene) => ((scene as Map)['checks'] as List).isEmpty), isTrue);
    },
    skip: Platform.environment.containsKey('MANA_LINEAGE_MANIFEST')
        ? false
        : 'Set MANA_LINEAGE_MANIFEST to an Ash export',
  );

  test('Markdown map and Mana JSON produce the same declared graph without criteria', () {
    final graph = momentGraph(scenes);
    expect(graphFromMap(map), graph);
    expect(graph['edges'], [
      {'from': 'checkout', 'to': 'approved'},
      {'from': 'checkout', 'to': 'declined'},
    ]);
    expect(graph['execution'], isNull);
    expect((graph['nodes']! as List).cast<Map>().every((node) => node['state'] == 'declared'), isTrue);
    expect(
      momentGraph({
        'declined': scenes['declined'],
        'approved': scenes['approved'],
        'checkout': scenes['checkout'],
      })['topologySha256'],
      graph['topologySha256'],
    );
  });

  test('unknown parents and cycles are rejected in both authoring formats', () {
    expect(
      () => momentGraph({
        'a': {'from': 'missing'},
      }),
      throwing('parent'),
    );
    expect(
      () => momentGraph({
        'a': {'from': 'a'},
      }),
      throwing('cycle'),
    );
    expect(
      () => momentGraph({
        'a': {'from': 'b'},
        'b': {'from': 'a'},
      }),
      throwing('cycle'),
    );
    expect(() => graphFromMap('# X\nmoments: 0.1\n## a\nfrom: b\n## b\nfrom: a'), throwing('cycle'));
    expect(() => graphFromMap(map.replaceFirst('moments: 0.1', 'moments: 9')), throwing('version'));
  });

  test('parent metadata survives export consumption and old manifest versions cannot silently flatten it', () {
    final (:project, :file, :manifest) = fixture();
    expect(manifestCatalog(file).firstWhere((item) => item['name'] == 'approved')['from'], 'checkout');
    for (final version in [1, 2]) {
      writeJson(file, {
        ...manifest,
        'version': version,
        'screens': {
          '/checkout': {'properties': manifest['properties']},
        },
      });
      expect(() => readManifest(file), throwing('version 3'));
    }
    writeJson(file, {
      ...manifest,
      'protocol': {...protocol, 'version': '9'},
    });
    expect(() => readManifest(file), throwing('protocol'));
  });

  test('graph CLI works offline, ignores private instance data and never executes adapter code', () async {
    final (:project, :file, manifest: _) = fixture();
    File(p.join(project, 'moments/backend.json')).writeAsStringSync('{"version":1,"name":"x","dll":"must not load"}');
    File(p.join(project, 'moments/.backend/instance.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('PRIVATE INVALID JSON');
    List<String> listing() =>
        [for (final e in Directory(p.join(project, 'moments')).listSync(recursive: true)) e.path]..sort();
    final before = File(file).readAsStringSync(), files = listing();
    final run = await moments(['graph', '--json', '--project', project], cwd: temporary());
    final result = (jsonDecode(run.stdout) as Map).cast<String, Object?>();
    expect((result['nodes']! as List).length, 3);
    expect(result['execution'], isNull);
    expect(run.stdout.contains('PRIVATE'), isFalse);
    expect(File(file).readAsStringSync(), before);
    expect(listing(), files);
  });

  test(
    'capability discovery needs no project and distinguishes schema from protocol and declarations from proof',
    () async {
      final run = await moments(['capabilities', '--json'], cwd: temporary());
      final result = (jsonDecode(run.stdout) as Map).cast<String, Object?>();
      expect(result, capabilities());
      expect(result['version'], 1);
      expect((result['protocol']! as Map)['version'], '0.1');
      expect(result['conformance'], 'partial');
      final declared = (result['capabilities']! as Map).cast<String, Object?>();
      expect(declared['independentFork'], true);
      expect(declared['parentMaterialization'], true);
      expect(declared['wholeSituationSnapshot'], false);
      final profiles = (result['executionProfiles']! as Map).cast<String, Object?>();
      expect((profiles['launcher']! as Map)['parentMaterialization'], false);
      expect((profiles['materialized']! as Map)['parentMaterialization'], true);
      expect((profiles['materialized']! as Map)['verification'], contains('Explicit check'));
      expect((result['semantics']! as Map)['reset --discard-data'], contains('not protocol reset'));
    },
  );

  test('child preparation fails before acquiring ownership, seeding, invoking recipes or committing', () async {
    final (project: _, :file, manifest: _) = fixture();
    final effects = <String>[];
    final backend = BackendRecipes(
      manifestFile: file,
      recipes: {
        'checkout': RecipeAdapter(
          prepare: (_) async {
            effects.add('recipe');
            return null;
          },
          inspect: (_, _) async => {},
        ),
      },
      instance: () => {},
      assertAvailable: () async => effects.add('available'),
      acquire: () {
        effects.add('lease');
        return () {};
      },
      commit: (_, {base, preparedMoment}) async => effects.add('commit'),
      startBase: (_) async => effects.add('base'),
      beforePrepare: (_) async => effects.add('checkpoint'),
    );
    await expectLater(backend.prepare('approved'), throwing('Parent materialization'));
    expect(effects, isEmpty);
  });

  test('direct Flutter runtime cannot flatten a child or change saved UI when opening it', () {
    final (:project, :file, manifest: _) = fixture();
    final runtime = Moments.create(project, MomentsOptions(manifestFile: file, initialName: 'checkout'))!;
    addTearDown(runtime.close);
    final before = File(p.join(project, 'moments/.session.json')).readAsStringSync();
    expect(() => runtime.open('approved'), throwing('Parent materialization'));
    expect(File(p.join(project, 'moments/.session.json')).readAsStringSync(), before);
    expect((runtime.inspect()['state']! as Map)['name'], 'checkout');
  });

  test('journey runner rejects an unsupported child before any runtime or gesture request', () async {
    final (:project, file: _, manifest: _) = fixture();
    final calls = <String>[];
    final result = await checkMoment(
      project: project,
      name: 'approved',
      journey: true,
      request: (path, [data]) async {
        calls.add(path);
        throw const MomentsError('must not request');
      },
    );
    expect(result['status'], 'unavailable');
    expect(calls, isEmpty);
  });

  test(
    'a coordinator-bound child inherits the checkpoint and rejects legacy open/reset and declaration drift',
    () async {
      final (:project, :file, :manifest) = fixture();
      (manifest['properties']! as Map)['draft'] = {'type': 'string', 'maxLength': 120};
      for (final value in (manifest['moments']! as Map).values) {
        ((value as Map)['projection'] as Map)['draft'] = 'declaration default';
      }
      writeJson(file, manifest);
      final session = p.join(project, 'moments/.session.json');
      Moments.create(project, MomentsOptions(manifestFile: file, initialName: 'checkout'))!.close();
      final saved = (readJson(session)! as Map).cast<String, Object?>();
      (((saved['states']! as Map)['checkout'] as Map)['projection'] as Map)['draft'] = 'Inherited parent draft';
      writeJson(session, saved);
      final materialization = {
        'instanceId': '00000000-0000-4000-8000-000000000001',
        'moment': 'approved',
        'from': 'checkout',
        'manifest': readManifest(file)['recipeHash'],
      };
      final child = Moments.create(project, MomentsOptions(manifestFile: file, materialization: materialization))!;
      addTearDown(child.close);
      final state = (child.inspect()['state']! as Map).cast<String, Object?>();
      expect(state['name'], 'approved');
      expect((state['projection']! as Map)['draft'], 'Inherited parent draft');
      expect(child.inspect()['materialization'], materialization);
      final before = File(session).readAsStringSync();
      expect(() => child.open('declined'), throwing('coordinator'));
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        try {
          await child.handle(
            request,
            request.uri,
            () async => (jsonDecode(await utf8.decoder.bind(request).join()) as Map).cast(),
          );
        } on Object catch (error) {
          reply(request.response, 400, {'error': error is MomentsError ? error.message : '$error'});
        }
      });
      Future<({int code, Object? body})> send(String path, [Map<String, Object?>? data]) async {
        final client = HttpClient();
        try {
          final request = await client.openUrl(
            data == null ? 'GET' : 'POST',
            Uri.parse('http://127.0.0.1:${server.port}$path'),
          );
          if (data != null) request.add(utf8.encode(jsonEncode(data)));
          final response = await request.close();
          return (code: response.statusCode, body: jsonDecode(await utf8.decoder.bind(response).join()));
        } finally {
          client.close(force: true);
        }
      }

      final reset = await send('/moments/reset', {});
      expect(reset.code, 400);
      expect('${(reset.body! as Map)['error']}', contains('coordinator'));
      final reopen = await send('/moments/open', {'name': 'approved', 'prepare': false});
      expect(reopen.code, 400);
      expect('${(reopen.body! as Map)['error']}', contains('cannot prepare'));
      expect(File(session).readAsStringSync(), before);
      final listing = await send('/moments/ls');
      expect((listing.body! as List).cast<Map>().firstWhere((v) => v['name'] == 'approved')['from'], 'checkout');
      scene(manifest, 'approved')['description'] = 'Changed';
      writeJson(file, manifest);
      expect(child.inspect, throwing('declaration changed'));
    },
  );

  test('materialized actor binding refuses missing or mismatched parent checkpoints before modifying them', () {
    final (:project, :file, manifest: _) = fixture();
    final session = p.join(project, 'moments/.session.json');
    Moments.create(project, MomentsOptions(manifestFile: file, initialName: 'checkout'))!.close();
    final before = File(session).readAsStringSync();
    final context = {
      'instanceId': '00000000-0000-4000-8000-000000000001',
      'moment': 'approved',
      'from': 'checkout',
      'manifest': readManifest(file)['recipeHash'],
    };
    for (final override in <Map<String, Object?>>[
      {'from': 'declined'},
      {'from': 'approved'},
      {'manifest': 'b' * 64},
      {'instanceId': 'bad'},
      {'token': 'DO NOT LEAK'},
    ]) {
      expect(
        () => Moments.create(project, MomentsOptions(manifestFile: file, materialization: {...context, ...override})),
        throwing('[Mm]aterialized'),
        reason: '$override',
      );
      expect(File(session).readAsStringSync(), before);
    }
  });

  test('parallel and nested timings remain separate observations, not an additive wall-time breakdown', () {
    final profile = journeyProfile(profileReport(), requiresBackend: true);
    expect(profile['status'], 'measured');
    expect((profile['latency']! as Map)['totalMs'], 15);
    final backend = (profile['backend']! as Map).cast<String, Object?>();
    expect(backend['sumRequestMs'], 18);
    expect((backend['database']! as Map)['queries'], 2);
    expect(((backend['actions']! as List).first as Map)['sumInclusiveMs'], 9);
    expect((backend['database']! as Map)['requestsObserved'], 1);
  });

  test('missing, old and truncated evidence remains partial; failed journeys never become successful', () {
    List<Map> receipts(Map<String, Object?> r) => ((r['actions']! as Map)['receipts'] as List).cast<Map>();
    for (final change in <void Function(Map<String, Object?> r)>[
      (r) => (r['actions']! as Map)['receipts'] = <Object?>[],
      (r) => (r['actions']! as Map)['overflow'] = true,
      (r) => receipts(r).first['truncated'] = true,
      (r) => receipts(r).first
        ..remove('profile')
        ..['version'] = 1,
    ]) {
      final r = profileReport();
      change(r);
      expect(journeyProfile(r, requiresBackend: true)['status'], 'partial');
    }
    final r = profileReport()..['status'] = 'failed';
    expect(journeyProfile(r)['journeyStatus'], 'failed');
    r['status'] = 'unavailable';
    expect(journeyProfile(r)['status'], 'unavailable');
    (r['actions']! as Map)['receipts'] = <Object?>[];
    expect(((journeyProfile(r)['backend']! as Map)['database'] as Map)['queries'], isNull);
  });
}
