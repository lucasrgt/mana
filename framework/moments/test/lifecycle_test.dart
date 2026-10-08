import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson;
import 'package:moments/src/down.dart';
import 'package:moments/src/lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

({String project, String directory}) fixture() {
  final project = temporary('mana-lifecycle-');
  final directory = p.join(project, 'moments', '.backend');
  Directory(directory).createSync(recursive: true);
  return (project: project, directory: directory);
}

Future<Process> child() async {
  final process = await Process.start('sleep', ['1000']);
  addTearDown(() => process.kill(ProcessSignal.sigkill));
  return process;
}

Lifecycle lifecycle(
  ({String project, String directory}) f, {
  List<int> ports = const [],
  Map<String, Object?>? android,
}) {
  final life = Lifecycle.create(project: f.project, directory: f.directory, ports: ports, android: android);
  addTearDown(life.finish);
  return life;
}

Map<String, Object?> identity(int pid) => identityJson(processIdentity(pid)!);

void main() {
  test('PID reuse or host reboot never authorizes a signal', () async {
    final process = await child();
    final owned = identity(process.pid);
    expect(sameProcess(owned), isTrue);
    expect(
      signalOwnedProcess({
        ...owned,
        'start': '${BigInt.parse(owned['start']! as String) + BigInt.one}',
      }, ProcessSignal.sigterm),
      isFalse,
    );
    expect(
      signalOwnedProcess({...owned, 'boot': '00000000-0000-0000-0000-000000000000'}, ProcessSignal.sigterm),
      isFalse,
    );
    expect(sameProcess(owned), isTrue);
    expect(signalOwnedProcess(owned, ProcessSignal.sigterm), isTrue);
    await process.exitCode;
    expect(sameProcess(owned), isFalse);
    expect(signalOwnedProcess(owned, ProcessSignal.sigkill), isFalse);
  });

  test('kernel ownership excludes concurrent down/up and releases after errors', () async {
    final (project: _, :directory) = fixture();
    await withInstanceLock(directory, () async {
      await expectLater(
        withInstanceLock(directory, () async => fail('Concurrent entry')),
        throwing('operation is running'),
      );
    });
    await expectLater(withInstanceLock(directory, () async => throw Exception('interrupted')), throwing('interrupted'));
    expect(await withInstanceLock(directory, () async => 42), 42);
  });

  test('journal records owned children and descendants, excluding unrelated processes', () async {
    final f = fixture();
    final life = lifecycle(f, ports: [5198]);
    final unrelated = await child();
    final parent = await Process.start('sh', ['-c', r'sleep 1000 & echo $!; wait']);
    addTearDown(() => parent.kill(ProcessSignal.sigkill));
    life.track(parent, 'flutter');
    final descendant = int.parse((await parent.stdout.transform(utf8.decoder).first).trim());
    addTearDown(() => Process.killPid(descendant, ProcessSignal.sigkill));
    life.scan();
    final stored = validateLifecycle(readJson(p.join(f.directory, 'running.json')), f.project);
    final processes = (stored['processes']! as List).cast<Map>();
    expect(processes.any((record) => record['pid'] == parent.pid), isTrue);
    expect(processes.any((record) => record['pid'] == descendant), isTrue);
    expect(processes.any((record) => record['pid'] == unrelated.pid), isFalse);
    expect(stored['databaseStarted'], false);
    life.claimDatabase();
    expect((readJson(p.join(f.directory, 'running.json'))! as Map)['databaseStarted'], true);
    final frozen = life.freeze();
    expect((frozen['processes']! as List).length, 2);
    life.finish();
    expect(File(p.join(f.directory, 'running.json')).existsSync(), isFalse);
  });

  test('foreign workspace, corrupt process and legacy journals fail before cleanup', () async {
    final f = fixture(), other = fixture();
    final life = lifecycle(f);
    expect(() => validateLifecycle(life.state, other.project), throwing('ownership'));
    expect(
      () => validateLifecycle({
        ...life.state,
        'supervisor': {'pid': 1},
      }, f.project),
      throwing('process ownership'),
    );
    life.finish();
    writeJson(p.join(f.directory, 'running.json'), {'pid': 123});
    await expectLater(downInstance(f.project), throwing('ownership'));
    expect(File(p.join(f.directory, 'running.json')).existsSync(), isTrue);
  });

  test('live supervisor without bridge is never treated as an orphan', () async {
    final f = fixture();
    final life = lifecycle(f);
    await expectLater(downInstance(f.project), throwing('still starting'));
    expect(sameProcess((life.state['supervisor']! as Map).cast()), isTrue);
    expect(File(p.join(f.directory, 'running.json')).existsSync(), isTrue);
  });

  test('service labels bind to instance, execution and workspace without credentials', () {
    final f = fixture();
    final life = lifecycle(f);
    final labels = momentDockerLabels({...life.environment(), 'SECRET': 'do-not-copy'}).join(' ');
    expect(labels, contains('dev.moments.role=service'));
    expect(labels, contains(life.state['runId']));
    expect(labels, isNot(contains('do-not-copy')));
    expect(momentDockerLabels({}), <String>[]);
    expect(() => momentDockerLabels({'MANA_RESOURCE_OWNER': 'invalid'}), throwing('ownership'));
  });

  test('kernel operation lock is released when its caller is killed', () async {
    final (project: _, :directory) = fixture();
    final holder = await Process.start(Platform.resolvedExecutable, [
      p.join(package, 'test/programs/lock_holder.dart'),
      directory,
    ]);
    addTearDown(() => holder.kill(ProcessSignal.sigkill));
    await holder.stdout.transform(utf8.decoder).first;
    await expectLater(withInstanceLock(directory, () async {}), throwing('operation is running'));
    final owned = identity(holder.pid);
    signalOwnedProcess(owned, ProcessSignal.sigkill);
    await holder.exitCode;
    var acquired = false;
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    while (!acquired && DateTime.now().isBefore(deadline)) {
      try {
        await withInstanceLock(directory, () async {});
        acquired = true;
      } on Object {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(acquired, isTrue, reason: 'No timeout file or manual stale-lock deletion');
  });

  test('a copied runtime descriptor cannot stop a different supervisor', () async {
    final f = fixture();
    final life = lifecycle(f, ports: [18751]);
    writeJson(p.join(f.directory, '.runtime.json'), {
      'url': 'http://127.0.0.1:18751',
      'pid': 1,
      'token': 'private-test-token',
    });
    await expectLater(downInstance(f.project), throwing('does not match execution ownership'));
    expect(sameProcess((life.state['supervisor']! as Map).cast()), isTrue);
  });

  test('uncommitted database metadata prevents a false successful recovery', () async {
    final f = fixture();
    final life = lifecycle(f);
    life.claimDatabase();
    await expectLater(stopOwnedResources(life.state), throwing('no committed instance metadata'));
    expect(File(p.join(f.directory, 'running.json')).existsSync(), isTrue);
  });

  test('temporary compilation files are scoped to one execution and preserved until verified finish', () {
    final f = fixture();
    final life = lifecycle(f);
    final path = flutterTemporaryDirectory(f.directory, life.state['runId']! as String);
    Directory(path).createSync(recursive: true);
    File(p.join(path, 'kernel.dill')).writeAsStringSync('owned artifact');
    final other = p.join(f.directory, 'tmp', 'unrelated');
    Directory(other).createSync(recursive: true);
    File(p.join(other, 'keep')).writeAsStringSync('other execution');
    life.freeze();
    expect(Directory(path).existsSync(), isTrue, reason: 'Freezing for recovery must retain temporary files');
    expect(() => clearFlutterTemporaryFiles(f.directory, '../unrelated'), throwing('Invalid'));
    life.finish();
    expect(Directory(path).existsSync(), isFalse);
    expect(File(p.join(other, 'keep')).existsSync(), isTrue);
  });

  test('Android registry is versioned and bounded to lifecycle ports before publication', () {
    final f = fixture();
    final android = {
      'device': 'emulator-5554',
      'ports': [5298, 18761],
    };
    final life = lifecycle(f, ports: [5298, 18761], android: android);
    expect(life.state['version'], 3);
    expect(validateLifecycle(life.state, f.project)['android'], android);
    expect(() => validateLifecycle({...life.state, 'version': 2}, f.project), throwing('version 3'));
    expect(
      () => validateLifecycle({
        ...life.state,
        'android': {
          ...android,
          'ports': [9999],
        },
      }, f.project),
      throwing('Android lifecycle'),
    );
    expect(
      () => validateLifecycle({
        ...life.state,
        'android': {...android, 'device': '-d'},
      }, f.project),
      throwing('Android lifecycle'),
    );
  });
}
