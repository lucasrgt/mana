import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState, uuidV4;
import 'package:moments/src/cli.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/flutter_actor.dart';
import 'package:moments/src/layers.dart';
import 'package:moments/src/managed.dart';
import 'package:moments/src/materializer.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

final class Files implements LayerDriver {
  Files(this.calls);
  final List<String> calls;
  @override
  String get type => 'files';
  @override
  Future<LayerHandle> materialize({
    required String dir,
    required String from,
    LayerOptions opts = const LayerOptions(),
  }) async => {};
  @override
  Future<void> capture({
    required LayerHandle handle,
    required String out,
    LayerOptions opts = const LayerOptions(),
  }) async {}
  @override
  Future<void> dispose({required LayerHandle handle, LayerOptions opts = const LayerOptions()}) async {}
  @override
  Future<void> forget({required String dir, LayerOptions opts = const LayerOptions()}) async {}
  @override
  Future<Map<String, Object?>> recover({
    required String dir,
    LayerOptions opts = const LayerOptions(),
    bool pending = false,
  }) async {
    calls.add('layer:$dir');
    return {'status': 'disposed'};
  }
}

final class Runtime implements MaterializerRuntime, RuntimeRecovery {
  Runtime(this.calls);
  final List<String> calls;
  @override
  var type = 'test-runtime';
  late Future<Map<String, Object?>> Function(String dir, String instanceId) recoverWith = (dir, instanceId) async {
    calls.add('runtime:$dir');
    return {'status': 'stopped', 'instanceId': instanceId};
  };
  @override
  Object allocate(World world) => Object();
  @override
  Future<void> start(Object handle, World world) async {}
  @override
  Future<void> stop(Object handle) async {}
  @override
  Null get executeJourney => null;
  @override
  Future<Map<String, Object?>> recover({required String dir, required String instanceId}) =>
      recoverWith(dir, instanceId);
}

/// A materializer run with no live instances; tests add instance records.
final class Fixture {
  Fixture() : dir = temporary('mana-run-recovery-') {
    final manifest = p.join(dir, 'manifest.json');
    savePrivateState(manifest, {
      'version': 3,
      'protocol': protocol,
      'watch': <Object?>[],
      'properties': {
        'route': {
          'enum': ['/'],
        },
      },
      'moments': {
        'root': {
          'projection': {'route': '/'},
          'checks': <Object?>[],
          'backend': {'recipe': 'root'},
        },
      },
    });
    runtime = Runtime(calls);
    layers = [(name: 'data', driver: Files(calls), root: 'unused', opts: const LayerOptions())];
    engine = Materializer.create(
      manifestFile: manifest,
      directory: dir,
      layers: layers,
      runtime: runtime,
      recipes: {'root': (_) async => throw const MomentsError('Never execute')},
      scope: 'recovery mechanism',
      codeIdentity: () => 'a' * 64,
    );
    run = (readJson(file)! as Map).cast();
  }

  final String dir;
  final calls = <String>[];
  late final Runtime runtime;
  late final List<Layer> layers;
  late final Materializer engine;
  late final Map<String, Object?> run;

  String get file => p.join(engine.home, 'run.json');
  void dead() => savePrivateState(file, {
    ...run,
    'supervisor': {...(run['supervisor']! as Map).cast<String, Object?>(), 'pid': 2147483647},
  });
  String add() {
    final id = uuidV4(), home = p.join(engine.home, 'instances', id);
    Directory(home).createSync(recursive: true);
    savePrivateState(p.join(home, 'instance.json'), {
      'version': 1,
      'id': id,
      'name': 'root',
      'scope': run['scope'],
      'code': run['code'],
      'manifest': run['manifest'],
      'phase': 'ready',
      'layers': {
        'data': {'dir': p.join(home, 'data'), 'phase': 'ready'},
      },
    });
    return home;
  }

  Future<Map<String, Object?>> recover() =>
      recoverMaterialization(directory: engine.home, layers: layers, runtime: runtime);
}

Future<({String project, String home})> actorRun() async {
  final project = temporary('mana-recover-cli-');
  Directory(p.join(project, 'moments')).createSync();
  final result = await Process.run(Platform.resolvedExecutable, [
    p.join(package, 'test/programs/actor_run.dart'),
    project,
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (project: project, home: (result.stdout as String).trim());
}

void main() {
  setUpAll(compileCli);

  group('materializer recovery', () {
    test('a live coordinator is refused without touching runtimes or data', () async {
      final f = Fixture()..add();
      await expectLater(f.recover(), throwing('supervisor is still alive'));
      expect(f.calls, isEmpty);
      await f.engine.close();
    });

    test('the complete inventory is validated before the first side effect', () async {
      final f = Fixture()
        ..dead()
        ..add();
      final bad = f.add(), file = p.join(bad, 'instance.json');
      final record = (readJson(file)! as Map).cast<String, Object?>();
      ((record['layers']! as Map)['data'] as Map)['dir'] = f.dir;
      savePrivateState(file, record);
      await expectLater(f.recover(), throwing('layer reference'));
      expect(f.calls, isEmpty);
    });

    test('every runtime stops before layer cleanup and a stop failure retains all layers', () async {
      final f = Fixture()
        ..dead()
        ..add()
        ..add();
      var n = 0;
      final stop = f.runtime.recoverWith;
      f.runtime.recoverWith = (dir, id) async {
        final receipt = await stop(dir, id);
        if (++n == 2) throw const MomentsError('Stop failed');
        return receipt;
      };
      await expectLater(f.recover(), throwing('Stop failed'));
      expect(f.calls.where((v) => v.startsWith('layer:')), isEmpty);
      f.runtime.recoverWith = stop;
      f.calls.clear();
      final result = await f.recover();
      expect(result['status'], 'disposed');
      expect(result['recipeReplayed'], false);
      expect(f.calls.take(2).every((v) => v.startsWith('runtime:')), isTrue);
      expect(f.calls.skip(2).every((v) => v.startsWith('layer:')), isTrue);
      expect(result['verification'], 'not-performed');
    });

    test('wrong adapter identity and unknown directories are refused before effects', () async {
      final f = Fixture()..dead();
      final dir = f.add();
      f.runtime.type = 'foreign';
      await expectLater(f.recover(), throwing('adapters'));
      f.runtime.type = 'test-runtime';
      Directory(p.join(dir, 'unrecorded')).createSync();
      await expectLater(f.recover(), throwing('Unrecorded layer'));
      expect(f.calls, isEmpty);
    });

    test('a callback without an instance stop receipt never releases data', () async {
      final f = Fixture()
        ..dead()
        ..add();
      f.runtime.recoverWith = (_, _) async => {};
      await expectLater(f.recover(), throwing('did not confirm'));
      expect(f.calls, isEmpty);
      expect((readJson(p.join(f.engine.home, 'recovery.json'))! as Map)['status'], 'attention');
    });
  });

  group('recover --run', () {
    test('recover --run is explicit and incompatible flags cannot affect other commands', () {
      expect(parseArgs(['recover', '--run', 'runs/one', '--json']).runDirectory, 'runs/one');
      for (final args in [
        ['recover', '--run'],
        ['open', 'root', '--run', 'x'],
        ['recover', '--browser-socket', 'x'],
        ['recover', '--run', 'x', '--browser-provider', 'a'],
        ['recover', '--run', 'x', '--run', 'y'],
      ]) {
        expect(() => parseArgs(args), throwsA(anything), reason: '$args');
      }
      expect(parseArgs(['recover']).runDirectory, isNull);
    });

    test('public CLI disposes a dead run, preserves roots and journal, and repeats safely', () async {
      final (:project, :home) = await actorRun();
      final journal = File(p.join(home, 'events.jsonl')).readAsBytesSync();
      for (var i = 0; i < 2; i++) {
        final result = await moments(['recover', '--run', home, '--project', project, '--json'], cwd: project);
        expect(result.code, 0, reason: result.stdout);
        final value = jsonDecode(result.stdout) as Map;
        expect(value['status'], 'disposed');
        expect(value['verification'], 'not-performed');
      }
      expect(File(p.join(home, 'events.jsonl')).readAsBytesSync(), journal);
      expect(File(p.join(project, 'moments/actor-root/actor-state.json')).existsSync(), isTrue);
      for (final instance in Directory(p.join(home, 'instances')).listSync()) {
        expect(File(p.join(instance.path, 'actor/actor-state.json')).existsSync(), isFalse);
      }
    });

    test('another project cannot recover a run before any side effect', () async {
      final (project: _, :home) = await actorRun();
      final other = temporary('mana-other-');
      Directory(p.join(other, 'moments')).createSync();
      final result = await moments(['recover', '--run', home, '--project', other, '--json'], cwd: other);
      expect(result.code, 2);
      expect(File(p.join(home, 'recovery.json')).existsSync(), isFalse);
    });

    test('a copied or legacy run without matching workspace metadata is refused in place', () async {
      final (:project, :home) = await actorRun();
      final file = p.join(home, 'run.json'), record = (readJson(file)! as Map).cast<String, Object?>();
      for (final workspace in [null, 'f' * 64]) {
        writeJson(file, {...record, 'workspace': workspace}..removeWhere((k, v) => k == 'workspace' && v == null));
        final result = await moments(['recover', '--run', home, '--project', project, '--json'], cwd: project);
        expect(result.code, 2);
        expect((jsonDecode(result.stdout) as Map)['reason'], contains('workspace registration'));
        expect(File(p.join(home, 'recovery.json')).existsSync(), isFalse);
      }
    });
  });
}
