import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show ArtifactFingerprint, uuidV4;
import 'package:moments/src/errors.dart';
import 'package:moments/src/execution_graph.dart';
import 'package:moments/src/layers.dart';
import 'package:moments/src/manifest.dart';
import 'package:moments/src/materializer.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// In-memory layer: a snapshot is a number keyed by its directory.
final class Memory implements LayerDriver {
  Memory(this.snapshots, this.handles, this.effects);
  final Map<String, Object?> snapshots;
  final Set<LayerHandle> handles;
  final List<String> effects;
  late Future<LayerHandle> Function(String dir, String from) materializeWith = (dir, from) async {
    final handle = <String, Object?>{'value': snapshots[from], 'live': false};
    handles.add(handle);
    effects.add('materialize');
    return handle;
  };
  late Future<void> Function(LayerHandle handle, String out) captureWith = (handle, out) async {
    if (handle['live'] == true) throw StateError('capture must follow runtime stop');
    snapshots[out] = handle['value'];
    effects.add('capture');
  };
  Future<Map<String, Object?>> Function(String dir)? recoverWith;

  @override
  String get type => 'memory';
  @override
  Future<LayerHandle> materialize({
    required String dir,
    required String from,
    LayerOptions opts = const LayerOptions(),
  }) => materializeWith(dir, from);
  @override
  Future<void> capture({required LayerHandle handle, required String out, LayerOptions opts = const LayerOptions()}) =>
      captureWith(handle, out);
  @override
  Future<void> dispose({required LayerHandle handle, LayerOptions opts = const LayerOptions()}) async {
    if (handle['live'] == true) throw StateError('dispose must follow runtime stop');
    handles.remove(handle);
    effects.add('dispose');
  }

  @override
  Future<void> forget({required String dir, LayerOptions opts = const LayerOptions()}) async => snapshots.remove(dir);
  @override
  Future<Map<String, Object?>> recover({
    required String dir,
    LayerOptions opts = const LayerOptions(),
    bool pending = false,
  }) {
    final recover = recoverWith;
    if (recover == null) throw const MomentsError('Partial layer needs an explicit recovery adapter');
    return recover(dir);
  }
}

typedef Journey =
    Future<Map<String, Object?>> Function(
      World world, {
      required String manifestFile,
      required String name,
      bool navigation,
      void Function()? assertCurrent,
    });

/// The runtime handle is the database layer handle itself, marked live.
final class Runtime implements MaterializerRuntime {
  Runtime(this.effects);
  final List<String> effects;
  late Future<void> Function(LayerHandle handle) startWith = (handle) async => handle['live'] = true;
  late Future<void> Function(LayerHandle handle) stopWith = (handle) async {
    handle['live'] = false;
    effects.add('stop');
  };
  Journey? journey;

  @override
  String get type => 'memory';
  @override
  Object allocate(World world) => world.handles['db']!;
  @override
  Future<void> start(Object handle, World world) => startWith(handle as LayerHandle);
  @override
  Future<void> stop(Object handle) => stopWith(handle as LayerHandle);
  @override
  Journey? get executeJourney => journey;
}

final class Fixture {
  Fixture({
    Map<String, TransitionRecipe> overrides = const {},
    void Function(Map<String, Object?> manifest)? configure,
    String Function()? identify,
  }) : directory = temporary('moment-materializer-') {
    configure?.call(manifest);
    writeJson(file, manifest);
    driver = Memory(snapshots, handles, effects);
    runtime = Runtime(effects);
    engine = Materializer.create(
      manifestFile: file,
      directory: p.join(directory, 'runs'),
      scope: 'memory mechanism test',
      layers: [(name: 'db', driver: driver, root: 'initial', opts: const LayerOptions())],
      runtime: runtime,
      recipes: {
        'root': (world) async {
          effects.add('root');
          world.handles['db']!['value'] = 1;
        },
        'child': (world) async {
          effects.add('child');
          world.handles['db']!['value'] = (world.handles['db']!['value']! as int) + 1;
        },
        ...overrides,
      },
      codeIdentity: identify ?? () => version,
    );
  }

  final String directory;
  final snapshots = <String, Object?>{'initial': 0};
  final handles = <LayerHandle>{};
  final effects = <String>[];
  var version = 'a' * 64;
  late final Memory driver;
  late final Runtime runtime;
  late final Materializer engine;
  final manifest = <String, Object?>{
    'version': 3,
    'protocol': protocol,
    'watch': <Object?>[],
    'properties': {
      'route': {
        'enum': ['/'],
      },
    },
    'moments': <String, Object?>{
      'root': <String, Object?>{
        'description': 'Root',
        'projection': {'route': '/'},
        'checks': <Object?>[],
        'backend': {'recipe': 'root'},
      },
      'child': <String, Object?>{
        'description': 'Child',
        'from': 'root',
        'projection': {'route': '/'},
        'checks': <Object?>[],
        'backend': {'recipe': 'child'},
      },
    },
  };

  String get file => p.join(directory, 'manifest.json');
  Map<String, Object?> moment(String name) => ((manifest['moments']! as Map)[name] as Map).cast();
  String get journal => p.join(engine.home, 'events.jsonl');
  List<Map<String, Object?>> events() => [
    for (final line in File(journal).readAsStringSync().trim().split('\n')) (jsonDecode(line) as Map).cast(),
  ];
  Map<String, Object?> graph([List<Object?>? events]) => executionGraph(readManifest(file), events ?? this.events());
  Map<String, Object?> execution([List<Object?>? events]) => (graph(events)['execution']! as Map).cast();
}

Object? db(World world, [String key = 'value']) => world.handles['db']![key];

void main() {
  setUpAll(compileCli);

  test('invalid transition requirements are rejected before allocating a layer', () async {
    final f = Fixture(
      configure: (manifest) => ((manifest['moments']! as Map)['child'] as Map)['steps'] = [
        {'kind': 'tap'},
      ],
    );
    await expectLater(f.engine.open('child'), throwing('actor-capable'));
    expect(f.effects, isEmpty);
    await f.engine.close();
  });

  test('a partially started runtime remains owned and is stopped before layer disposal', () async {
    final f = Fixture();
    LayerHandle? partial;
    f.runtime.startWith = (handle) async {
      partial = handle;
      handle['live'] = true;
      throw const MomentsError('Start failed after service creation');
    };
    await expectLater(f.engine.open('root'), throwing('Start failed'));
    expect(partial!['live'], true);
    expect(f.events().any((e) => e['type'] == 'runtime.ready' || e['type'] == 'snapshot.ready'), isFalse);
    await f.engine.close();
    expect(partial!['live'], false);
    expect(f.handles, isEmpty);
    expect(f.execution()['phaseAtLastEvent'], 'closed');
  });

  test('actor navigation captures criteria-free children once and refuses stale or foreign captures', () async {
    for (final defect in [null, 'missing', 'foreign', 'sequence', 'verification']) {
      final f = Fixture(
        configure: (manifest) => ((manifest['moments']! as Map)['child'] as Map)['steps'] = [
          {'name': 'press', 'kind': 'tap', 'target': 'action', 'until': <Object?>[]},
        ],
      );
      var gestures = 0;
      f.runtime.journey = (world, {required manifestFile, required name, navigation = true, assertCurrent}) async {
        assertCurrent!();
        expect(navigation, isTrue);
        gestures++;
        expect(db(world), 1);
        world.handles['db']!['value'] = 2;
        Map<String, Object?> frame(int sequence) => {
          'status': 'captured',
          'name': name,
          'id': uuidV4(),
          'client': 'actor',
          'revision': 'revision',
          'sequence': sequence,
        };
        final result = <String, Object?>{
          'status': 'captured',
          'operation': 'materialized-navigation',
          'name': name,
          'ownership': {'phase': 'idle'},
          'verification': 'not-performed',
          'materialization': {
            'instanceId': world.id,
            'moment': name,
            'from': world.materializedMoment,
            'manifest': readManifest(f.file)['recipeHash'],
          },
          'steps': [
            {'name': 'press', 'status': 'passed', 'dispatch': 'dispatched', 'capture': frame(1)},
          ],
          'capture': frame(2),
          'checks': <Object?>[],
        };
        if (defect == 'missing') result.remove('capture');
        if (defect == 'foreign') (result['materialization']! as Map)['instanceId'] = uuidV4();
        if (defect == 'sequence') (((result['steps']! as List).first as Map)['capture'] as Map)['sequence'] = 2;
        if (defect == 'verification') result['status'] = 'passed';
        return result;
      };
      if (defect == null) {
        expect(db(await f.engine.open('child')), 2);
      } else {
        await expectLater(f.engine.open('child'), throwing('fresh UI capture'));
        await expectLater(f.engine.open('child'), throwing('fresh UI capture'));
        expect(f.events().any((e) => e['type'] == 'snapshot.ready' && e['moment'] == 'child'), isFalse);
      }
      expect(gestures, 1, reason: '$defect');
      expect(f.effects.contains('child'), isFalse);
      await f.engine.close();
    }
  });

  test('a failed stop prevents capture and cleanup can retry without replaying the transition', () async {
    final f = Fixture();
    var attempts = 0;
    final stop = f.runtime.stopWith;
    f.runtime.stopWith = (handle) async {
      attempts++;
      if (attempts <= 2) throw const MomentsError('Actor has not stopped');
      await stop(handle);
    };
    await expectLater(f.engine.build('root'), throwing('Actor has not stopped'));
    expect(f.events().any((e) => e['type'] == 'snapshot.ready'), isFalse);
    expect(f.handles.length, 1);
    expect(f.handles.single['live'], true);
    await f.engine.close();
    expect(f.effects.where((e) => e == 'root').length, 1);
    expect(f.handles, isEmpty);
    expect(f.execution()['phaseAtLastEvent'], 'closed');
  });

  test(
    'failed transition is never retried and produces no successful child snapshot or invented verification',
    () async {
      var attempts = 0;
      final f = Fixture(
        overrides: {
          'child': (world) async {
            attempts++;
            world.handles['db']!['value'] = 7;
            throw const MomentsError('PRIVATE TOKEN SENTINEL');
          },
        },
      );
      await expectLater(f.engine.open('child'), throwing('PRIVATE TOKEN SENTINEL'));
      await expectLater(f.engine.open('child'), throwing('PRIVATE TOKEN SENTINEL'));
      expect(attempts, 1);
      expect(f.handles, isEmpty);
      expect(f.events().any((e) => e['type'] == 'snapshot.ready' && e['moment'] == 'child'), isFalse);
      expect(jsonEncode(f.events()).contains('PRIVATE TOKEN'), isFalse);
      await f.engine.close();
      expect(f.snapshots.length, 1);
    },
  );

  test('code changing during a transition cannot publish a snapshot under the previous version', () async {
    late Fixture f;
    f = Fixture(overrides: {'child': (_) async => f.version = 'b' * 64});
    await expectLater(f.engine.open('child'), throwing('Code or Moment declaration changed'));
    expect(f.events().any((e) => e['type'] == 'snapshot.ready' && e['moment'] == 'child'), isFalse);
    await f.engine.close();
    expect(f.handles, isEmpty);
  });

  test('incremental artifact identity rejects a same-size mtime-preserving write during a transition', () async {
    final artifact = temporary('moment-artifact-change-');
    final binary = File(p.join(artifact, 'app'))..writeAsStringSync('before');
    final scanner = ArtifactFingerprint(artifact), modified = binary.lastModifiedSync();
    // The transition must invalidate already-reused bytes.
    scanner.snapshot();
    final f = Fixture(
      overrides: {
        'child': (_) async {
          binary.writeAsStringSync('after!');
          binary.setLastModifiedSync(modified);
        },
      },
      identify: () => scanner.snapshot().sha256,
    );
    await expectLater(f.engine.open('child'), throwing('Code or Moment declaration changed'));
    expect(f.events().any((e) => e['type'] == 'snapshot.ready' && e['moment'] == 'child'), isFalse);
    await f.engine.close();
    expect(f.handles, isEmpty);
  });

  test('concurrent children share one built parent but have independent live handles', () async {
    final f = Fixture();
    final [a, b] = await Future.wait([f.engine.open('child'), f.engine.open('root')]);
    expect(f.effects.where((value) => value == 'root').length, 1);
    expect(db(a), 2);
    expect(db(b), 1);
    a.handles['db']!['value'] = 99;
    expect(db(b), 1);
    final childReady = f.events().where((e) => e['type'] == 'runtime.ready' && e['moment'] == 'child');
    expect(childReady.map((e) => e['materializedMoment']), ['root', 'child']);
    await f.engine.close();
    expect(f.handles, isEmpty);
    expect(f.snapshots.length, 1);
  });

  test('close waits for in-flight work and rejects new work instead of disposing underneath a transition', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final f = Fixture(
      overrides: {
        'child': (world) async {
          entered.complete();
          await release.future;
          expect(db(world, 'live'), true);
        },
      },
    );
    final opening = f.engine.open('child');
    await entered.future;
    final closing = f.engine.close();
    await expectLater(f.engine.open('root'), throwing('closing'));
    release.complete();
    await opening;
    await closing;
    expect(f.handles, isEmpty);
    expect(f.events().last['type'], 'closed');
  });

  test('cleanup is idempotent and refuses handles owned by another coordinator', () async {
    final first = Fixture(), second = Fixture();
    final a = await first.engine.open('root'), b = await second.engine.open('root');
    await expectLater(first.engine.dispose(b), throwing('does not belong'));
    expect(db(b, 'live'), true);
    await first.engine.dispose(a);
    await first.engine.dispose(a);
    final closed = first.engine.close();
    expect(identical(first.engine.close(), closed), isTrue);
    await closed;
    expect(first.events().where((e) => e['type'] == 'closed').length, 1);
    await second.engine.close();
  });

  test('execution graph projects only recorded transitions and never labels materialization as verification', () async {
    final f = Fixture();
    await f.engine.open('child');
    final live = f.graph();
    expect(
      [
        for (final e in (live['edges']! as List).cast<Map>()) {'from': e['from'], 'to': e['to']},
      ],
      [
        {'from': 'root', 'to': 'child'},
      ],
    );
    final execution = (live['execution']! as Map).cast<String, Object?>();
    final transitions = (execution['transitions']! as List).cast<Map>();
    expect(transitions.length, 2);
    expect(transitions.every((e) => e['status'] == 'completed'), isTrue);
    expect(execution['liveState'], 'not-probed');
    expect(execution['verification'], 'not-recorded');
    expect((execution['instances']! as List).cast<Map>().where((i) => i['phase'] == 'ready').length, 1);
    await f.engine.close();
    final closed = readExecutionGraph(readManifest(f.file), f.journal);
    final closedExecution = (closed['execution']! as Map).cast<String, Object?>();
    expect(closedExecution['phaseAtLastEvent'], 'closed');
    expect((closedExecution['instances']! as List).cast<Map>().every((i) => i['phase'] == 'disposed'), isTrue);
    final child = (closed['nodes']! as List).cast<Map>().firstWhere((n) => n['name'] == 'child');
    expect((child['evidence'] as Map)['verification'], 'not-recorded');
  });

  test(
    'graph shows an interrupted transition as incomplete and a failed transition without a child snapshot',
    () async {
      final f = Fixture(overrides: {'child': (_) async => throw const MomentsError('private')});
      await expectLater(f.engine.open('child'), throwsA(anything));
      final events = f.events();
      final start = events.indexWhere((e) => e['type'] == 'transition.started' && e['moment'] == 'child');
      final interrupted = f.execution(events.sublist(0, start + 1));
      expect(((interrupted['transitions']! as List).last as Map)['status'], 'started');
      expect(((interrupted['instances']! as List).last as Map)['materializedMoment'], 'root');
      final failed = f.graph(events);
      expect((((failed['execution']! as Map)['transitions']! as List).last as Map)['status'], 'failed');
      final child = (failed['nodes']! as List).cast<Map>().firstWhere((n) => n['name'] == 'child');
      expect((child['evidence'] as Map)['snapshots'], <Object?>[]);
      await f.engine.close();
    },
  );

  test(
    'graph rejects stale declarations, mixed or reordered journals, false lineage and fabricated verification',
    () async {
      final f = Fixture();
      await f.engine.open('child');
      await f.engine.close();
      final events = f.events(), manifest = readManifest(f.file);
      expect(() => executionGraph({...manifest, 'recipeHash': 'b' * 64}, events), throwing('declaration changed'));
      for (final change in <void Function(List<Map<String, Object?>> e)>[
        (e) => e[1]['sequence'] = (e[1]['sequence']! as int) + 1,
        (e) => e[1]['runId'] = '00000000-0000-4000-8000-000000000000',
        (e) => e.firstWhere((v) => v['type'] == 'transition.started' && v['moment'] == 'child')['from'] = null,
        (e) =>
            e.firstWhere((v) => v['type'] == 'runtime.ready' && v['moment'] == 'child')['materializedMoment'] = 'child',
        (e) => e.firstWhere((v) => v['type'] == 'transition.completed')['type'] = 'verified',
      ]) {
        final edited = [for (final e in events) (jsonDecode(jsonEncode(e)) as Map).cast<String, Object?>()];
        change(edited);
        expect(() => executionGraph(manifest, edited), throwing('Invalid materialization journal'));
      }
      File(f.journal).writeAsStringSync(File(f.journal).readAsStringSync().trimRight());
      expect(() => readExecutionGraph(manifest, f.journal), throwing('incomplete last record'));
    },
  );

  test('graph CLI consumes only matching declaration and journal without loading backend adapters', () async {
    final f = Fixture();
    await f.engine.open('child');
    await f.engine.close();
    final project = p.join(f.engine.home, 'project');
    Directory(p.join(project, 'moments')).createSync(recursive: true);
    File(f.file).copySync(p.join(project, 'moments/manifest.json'));
    File(p.join(project, 'moments/backend.json')).writeAsStringSync('{"version":1,"name":"x","dll":"must not load"}');
    final run = await moments(['graph', '--project', project, '--events', f.journal, '--json'], cwd: project);
    final result = (jsonDecode(run.stdout) as Map).cast<String, Object?>();
    expect((result['execution']! as Map)['phaseAtLastEvent'], 'closed');
    final edges = (result['edges']! as List).cast<Map>();
    expect(edges.length, 1);
    expect((edges.single['transitions'] as List).length, 1);
    expect((await moments(['check', 'child', '--events', f.journal], cwd: project)).code, isNot(0));
  });

  test('partial materialization remains inventoried and close recovers without allocating again', () async {
    final f = Fixture();
    var allocations = 0, recoveries = 0;
    Map<String, Object?> record(String dir) => (readJson(p.join(p.dirname(dir), 'instance.json'))! as Map).cast();
    f.driver.materializeWith = (dir, from) async {
      allocations++;
      final db = (record(dir)['layers']! as Map)['db'] as Map;
      expect(db['dir'], dir);
      expect(db['phase'], 'materializing');
      throw const MomentsError('Creation completed but acknowledgement was lost');
    };
    await expectLater(f.engine.open('root'), throwing('acknowledgement'));
    await expectLater(f.engine.close(), throwing('cleanup needs inspection'));
    f.driver.recoverWith = (dir) async {
      expect(((record(dir)['layers']! as Map)['db'] as Map)['phase'], 'materializing');
      recoveries++;
      return {'status': 'disposed'};
    };
    await f.engine.close();
    expect(allocations, 1);
    expect(recoveries, 1);
    expect(f.execution()['phaseAtLastEvent'], 'closed');
  });

  test('partial snapshot capture stays owned until explicit recovery succeeds', () async {
    final f = Fixture();
    final capture = f.driver.captureWith;
    var captures = 0, recoveries = 0;
    f.driver.captureWith = (handle, out) async {
      captures++;
      final record = (readJson(p.join(p.dirname(out), 'snapshot.json'))! as Map).cast<String, Object?>();
      expect((record['pendingLayers']! as Map)['db'], out);
      expect(record['phase'], 'capturing');
      await capture(handle, out);
      throw const MomentsError('Capture reply lost');
    };
    f.driver.recoverWith = (dir) async {
      recoveries++;
      if (recoveries == 1) throw const MomentsError('Storage unavailable');
      f.snapshots.remove(dir);
      return {'status': 'disposed'};
    };
    await expectLater(f.engine.build('root'), throwing('Capture reply lost'));
    await expectLater(f.engine.close(), throwing('cleanup needs inspection'));
    expect(f.events().any((e) => e['type'] == 'snapshot.ready'), isFalse);
    await f.engine.close();
    expect(captures, 1);
    expect(recoveries, 2);
    expect(f.snapshots.length, 1);
    expect(f.effects.where((e) => e == 'root').length, 1);
  });
}
