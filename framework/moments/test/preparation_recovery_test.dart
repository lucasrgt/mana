import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState, uuidV4;
import 'package:moments/src/cli.dart';
import 'package:moments/src/lifecycle.dart';
import 'package:moments/src/managed.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));
Matcher throwingAny(List<String> texts) =>
    throwsA(predicate((e) => texts.any('$e'.contains), 'mentions one of $texts'));

typedef Docker = String Function(List<String> args);

void privateDirectory(String dir) {
  Directory(dir).createSync(recursive: true);
  Process.runSync('chmod', ['700', dir]);
}

Map<String, Object?> read(String file) => (readJson(file)! as Map).cast();

final class Fixture {
  Fixture._(this.project, this.directory, this.handle, this.api, this.db, this.rows);
  final String project, directory, api, db;
  final ({Future<void> Function() close, Future<void> Function() attention}) handle;
  final Map<String, Map<String, Object?>> rows;
  final stops = <String>[];
  var lose = false;
  String get lifecycle => p.join(project, 'moments/.backend');

  static Future<Fixture> create() async {
    final project = temporary('mana-preparation-'), directory = p.join(project, 'moments/.proofs/profile');
    privateDirectory(directory);
    final owner = uuidV4(), api = 'test-api-$owner', db = 'test-db-$owner';
    final handle = await registerPreparation(
      project: project,
      directory: directory,
      resources: {
        'processes': <String>[],
        'containers': <String>[],
        'services': [
          {
            'record': 'instance.json',
            'ownerField': 'id',
            'label': 'dev.mana.test-owner',
            'stop': ['api'],
            'preserve': ['database'],
          },
        ],
      },
    );
    addTearDown(handle.attention);
    savePrivateState(p.join(directory, 'instance.json'), {'id': owner, 'api': api, 'database': db});
    Map<String, Object?> row(String id, String name) => {
      'Id': id,
      'Name': '/$name',
      'Config': {
        'Labels': {'dev.mana.test-owner': owner},
      },
      'State': {'Running': true},
    };
    return Fixture._(project, directory, handle, api, db, {api: row('a' * 64, api), db: row('b' * 64, db)});
  }

  Map<String, Object?> state(String name) => (rows[name]!['State']! as Map).cast();

  String docker(List<String> args) {
    switch (args.first) {
      case 'ps':
        final filter = args.last, name = filter.substring(7, filter.length - 1);
        return (rows[name]?['Id'] as String?) ?? '';
      case 'inspect':
        return jsonEncode([rows.values.firstWhere((v) => v['Id'] == args[1])]);
      case 'stop':
        stops.add(args.last);
        final row = rows.values.firstWhere((v) => v['Id'] == args.last);
        (row['State']! as Map)['Running'] = false;
        if (lose) throw StateError('Lost stop reply');
        return row['Id']! as String;
    }
    throw StateError('Unexpected Docker command');
  }

  Future<void> dead() async {
    await handle.attention();
    final file = p.join(directory, 'preparation-ownership.json'), record = read(file);
    (record['supervisor']! as Map)['pid'] = 2147483647;
    savePrivateState(file, record);
  }

  Future<Map<String, Object?>> recover({String? project, Docker? docker}) =>
      recoverPreparation(project ?? this.project, directory: directory, docker: docker ?? this.docker);
}

const _empty = {'processes': <String>[], 'containers': <String>[], 'services': <Object>[]};

void main() {
  late String owner;
  setUpAll(() async {
    await compileCli();
    owner = await compileProgram('test/programs/preparation_owner.dart');
  });

  test('preparation recovery options and paths are bounded', () {
    expect(parseArgs(['prepare', '--profile', 'local']).command, 'prepare');
    expect(parseArgs(['recover', '--preparation', 'p']).preparationDirectory, 'p');
    for (final args in [
      ['prepare'],
      ['recover', '--preparation', 'p', '--session', 's'],
      ['recover', '--preparation', 'p', '--run', 'r'],
      ['compose', '--preparation', 'p'],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
    for (final resources in [
      {
        'processes': ['../foreign'],
        'containers': <String>[],
        'services': <Object>[],
      },
      {
        'processes': ['x'],
        'containers': ['x'],
        'services': <Object>[],
      },
      {
        'processes': <String>[],
        'containers': <String>[],
        'services': [
          {
            'record': '../foreign.json',
            'ownerField': 'id',
            'label': 'dev.mana.test',
            'stop': ['api'],
            'preserve': <String>[],
          },
        ],
      },
    ]) {
      expect(() => validatePreparationResources(resources), throwsA(anything), reason: '$resources');
    }
  });

  test('live preparation refuses recovery; dead preparation stops only its API and preserves DB', () async {
    final f = await Fixture.create();
    await expectLater(f.recover(), throwingAny(['lifecycle operation', 'still alive']));
    expect(f.stops, isEmpty);
    await f.dead();
    final r = await f.recover();
    expect(r['status'], 'closed');
    expect(r['recipeReplayed'], isFalse);
    expect(f.stops, ['a' * 64]);
    expect(f.state(f.db)['Running'], isTrue);
    f.state(f.api)['Running'] = true;
    final again = await f.recover();
    expect(again['resourcesTouched'], isFalse);
    expect(f.stops, hasLength(1));
    expect(f.state(f.api)['Running'], isTrue);
  });

  test('changed labels fail before service stop', () async {
    final f = await Fixture.create();
    await f.dead();
    ((f.rows[f.api]!['Config']! as Map)['Labels']! as Map)['dev.mana.test-owner'] = uuidV4();
    await expectLater(f.recover(), throwing('ownership changed'));
    expect(f.stops, isEmpty);
    expect(read(p.join(f.directory, 'preparation-ownership.json'))['phase'], 'attention');
  });

  test('lost stop reply pins the original ID; recovery cannot stop a replacement', () async {
    final f = await Fixture.create();
    await f.dead();
    f.lose = true;
    await expectLater(f.recover(), throwing('Lost stop'));
    f.rows[f.api]!['Id'] = 'c' * 64;
    f.state(f.api)['Running'] = true;
    await expectLater(f.recover(), throwing('replaced'));
    expect(f.stops, ['a' * 64]);
  });

  test('symbolic resource receipts and a different project are refused', () async {
    final f = await Fixture.create();
    await f.dead();
    final other = temporary('mana-preparation-other-');
    await expectLater(f.recover(project: other), throwing('selected project'));
    final instance = p.join(f.directory, 'instance.json'), moved = p.join(other, 'instance.json');
    File(instance).renameSync(moved);
    Link(instance).createSync(moved);
    await expectLater(f.recover(), throwing('symbolic'));
    expect(f.stops, isEmpty);
  });

  test('auto-removal between list and inspect requires a fresh confirmed absence', () async {
    final f = await Fixture.create();
    await f.dead();
    var stopped = false, listed = false;
    String docker(List<String> args) {
      if (args.first == 'stop') {
        final result = f.docker(args);
        stopped = true;
        return result;
      }
      if (stopped && args.first == 'ps' && args.last.contains(f.api) && !listed) {
        listed = true;
        final result = f.docker(args);
        f.rows.remove(f.api);
        return result;
      }
      if (listed && args.first == 'inspect' && args[1] == 'a' * 64) throw StateError('Container disappeared');
      return f.docker(args);
    }

    final r = await f.recover(docker: docker);
    expect(r['status'], 'closed');
    expect(f.stops, ['a' * 64]);
    expect(f.state(f.db)['Running'], isTrue);
  });

  test('inspect failure with a still-listed service remains attention', () async {
    final f = await Fixture.create();
    await f.dead();
    await expectLater(
      f.recover(
        docker: (args) => args.first == 'inspect' ? throw StateError('Observation unavailable') : f.docker(args),
      ),
      throwing('Observation unavailable'),
    );
    expect(f.stops, isEmpty);
  });

  test('public recovery does not require a manifest or run the project program', () async {
    final f = await Fixture.create();
    await f.dead();
    final path = p.join(f.directory, 'preparation-ownership.json'), record = read(path);
    (record['resources']! as Map)['services'] = <Object>[];
    savePrivateState(path, record);
    File(
      p.join(f.project, 'moments/adapters.dart'),
    ).writeAsStringSync('void main() => throw StateError("adapter ran");');
    final run = await moments([
      'recover',
      '--preparation',
      f.directory,
      '--project',
      f.project,
      '--json',
    ], cwd: f.project);
    expect(run.code, 0, reason: run.stderr);
    final result = jsonDecode(run.stdout) as Map;
    expect(result['status'], 'closed');
    expect(result['recipeReplayed'], isFalse);
  });

  test('one consumer excludes overlapping preparations and managed sessions until closure', () async {
    final f = await Fixture.create(), next = p.join(f.project, 'moments/.proofs/next');
    privateDirectory(next);
    Future<void> register() async =>
        (await registerPreparation(project: f.project, directory: next, resources: _empty)).close();
    await expectLater(register(), throwing('lifecycle operation'));
    expect(File(p.join(next, 'preparation-ownership.json')).existsSync(), isFalse);
    await expectLater(
      withInstanceLock(f.lifecycle, () async => assertNoManagedSession(f.lifecycle)),
      throwing('lifecycle operation'),
    );
    await f.handle.attention();
    await expectLater(register(), throwing('recover --preparation'));
    await expectLater(
      withInstanceLock(f.lifecycle, () async => assertNoManagedSession(f.lifecycle)),
      throwing('recover --preparation'),
    );
    await f.dead();
    await f.recover();
    await register();
    expect(File(p.join(f.lifecycle, 'preparation.json')).existsSync(), isFalse);
  });

  test('materialization ownership blocks preparation and nonterminal recovery before effects', () async {
    final f = await Fixture.create();
    await f.dead();
    final marker = p.join(f.lifecycle, 'materialization.json');
    savePrivateState(marker, {'directory': 'retained-session'});
    await expectLater(f.recover(), throwing('materialization session'));
    expect(f.stops, isEmpty);
    File(marker).deleteSync();
    await f.recover();
    savePrivateState(marker, {'directory': 'retained-session'});
    final directory = p.join(f.project, 'moments/.proofs/next');
    privateDirectory(directory);
    await expectLater(
      registerPreparation(project: f.project, directory: directory, resources: _empty),
      throwing('materialization session'),
    );
    expect(File(p.join(directory, 'preparation-ownership.json')).existsSync(), isFalse);
  });

  test('closed receipt reconciles its own stale marker without removing another owner', () async {
    final f = await Fixture.create(), marker = p.join(f.lifecycle, 'preparation.json');
    final old = read(marker);
    await f.handle.close();
    await f.dead();
    savePrivateState(marker, old);
    await f.recover();
    expect(File(marker).existsSync(), isFalse);
    final newer = {...old, 'id': uuidV4(), 'directory': 'another-profile'};
    savePrivateState(marker, newer);
    await f.recover();
    expect(read(marker), newer);
    expect(f.stops, isEmpty);
  });

  test('actual killed supervisor leaves a durable exclusion recoverable without application code', () async {
    final project = temporary('mana-killed-preparation-'), directory = p.join(project, 'moments/.proofs/killed');
    privateDirectory(directory);
    final child = await Process.start(Platform.resolvedExecutable, [owner, project, directory]);
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    unawaited(child.stderr.drain<void>());
    await child.stdout.transform(utf8.decoder).first.timeout(const Duration(seconds: 60));
    final lifecycle = p.join(project, 'moments/.backend');
    await expectLater(
      withInstanceLock(lifecycle, () async => assertNoManagedSession(lifecycle)),
      throwing('lifecycle operation'),
    );
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
    // The lock helper notices the dead parent asynchronously. Retry only the
    // read-only acquisition, never preparation or resource creation.
    var acquired = false;
    for (var i = 0; i < 50 && !acquired; i++) {
      try {
        await withInstanceLock(lifecycle, () async {
          acquired = true;
          expect(() => assertNoManagedSession(lifecycle), throwing('recover --preparation'));
        });
      } on Object catch (error) {
        if (!'$error'.contains('lifecycle operation')) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    expect(acquired, isTrue);
    final result = await recoverPreparation(project, directory: directory);
    expect(result['status'], 'closed');
    expect(result['recipeReplayed'], isFalse);
    await withInstanceLock(lifecycle, () async => assertNoManagedSession(lifecycle));
  });

  test('session recovery cannot bypass an interrupted preparation marker', () async {
    final f = await Fixture.create();
    await f.dead();
    final home = p.join(f.project, 'moments/.proofs/materializations', uuidV4());
    privateDirectory(home);
    await expectLater(recoverManagedSession(f.project, directory: home), throwing('recover --preparation first'));
    expect(f.stops, isEmpty);
    expect(File(p.join(f.lifecycle, 'preparation.json')).existsSync(), isTrue);
  });
}
