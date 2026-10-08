import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState, uuidV4;
import 'package:moments/src/lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const _docker = r'''#!/usr/bin/env python3
import json, os, sys
file = os.environ['MANA_TEST_DOCKER']
s = json.load(open(file)); args = sys.argv[1:]; s['calls'].append(args)
def save(): json.dump(s, open(file, 'w'))
c = s.get('container')
if args[0] == 'ps':
    name = next((v for v in args if v.startswith('name=')), None)
    print(c['Id'] if c and (not name or name == 'name=^/' + c['Name'][1:] + '$') else '')
elif args[0] == 'inspect':
    if not c: save(); sys.exit(1)
    print(json.dumps([c]))
elif args[0] == 'rm':
    s['container'] = None
    if s.get('removeThenFail'):
        s['removeThenFail'] = False; save(); sys.exit(1)
else:
    save(); sys.exit(2)
save()
''';

/// A stopped, owned database instance whose preparation was interrupted.
final class Fixture {
  Fixture() : project = temporary('mana-startup-') {
    directory = p.join(project, 'moments', '.backend');
    Directory(directory).createSync(recursive: true);
    final bin = p.join(project, 'bin');
    Directory(bin).createSync();
    File(p.join(bin, 'docker')).writeAsStringSync(_docker);
    Process.runSync('chmod', ['700', p.join(bin, 'docker')]);
    environment = {'PATH': '$bin:${Platform.environment['PATH']}', 'MANA_TEST_DOCKER': p.join(project, 'docker.json')};
    final id = uuidV4(), workspace = workspaceIdentity(project);
    instance = {
      'id': id,
      'container': 'moments-$id',
      'workspace': workspace,
      'databasePhase': 'ready',
      'password': 'PRIVATE-PASSWORD',
      'jwtSecret': 'PRIVATE-TOKEN',
      'launch': {
        'session': {'token': 'PRIVATE-SESSION'},
      },
      'preparation': {'moment': 'inbox', 'stage': 'services', 'startedAt': DateTime.now().toUtc().toIso8601String()},
      'phase': 'ready',
    };
    container = {
      'Id': 'a' * 64,
      'Name': '/moments-$id',
      'State': {'Running': false},
      'Config': {
        'Labels': <String, Object?>{
          'dev.moments.owner': id,
          'dev.moments.workspace': workspace,
          'dev.moments.role': 'database',
        },
      },
    };
    saveDocker(container: container);
    save();
  }

  final String project;
  late final String directory;
  late final Map<String, String> environment;
  late final Map<String, Object?> instance, container;

  String get manifest => p.join(directory, 'instance.json');
  Map<String, Object?> get labels => ((container['Config']! as Map)['Labels']! as Map).cast();

  void save() => savePrivateState(manifest, instance);
  void saveDocker({Map<String, Object?>? container, bool removeThenFail = false}) => writeJson(
    environment['MANA_TEST_DOCKER']!,
    {'calls': <Object?>[], 'container': container, 'removeThenFail': removeThenFail},
  );
  Map<String, Object?> docker() => (readJson(environment['MANA_TEST_DOCKER']!)! as Map).cast();
  List<List> calls() => (docker()['calls']! as List).cast<List>();

  Future<Map<String, Object?>> run(String operation) async {
    final result = await Process.run(Platform.resolvedExecutable, [
      p.join(package, 'test/programs/instance_ops.dart'),
      operation,
      project,
    ], environment: environment);
    return (jsonDecode(result.stdout as String) as Map).cast();
  }
}

Matcher fails(String text) => predicate<Map<String, Object?>>(
  (r) => r['ok'] == false && '${r['error']}'.contains(text),
  'fails mentioning "$text"',
);
final succeeds = predicate<Map<String, Object?>>((r) => r['ok'] == true, 'succeeds');

void main() {
  test(
    'local inspection exposes stage and resource state without launching adapters or exposing credentials',
    () async {
      final f = Fixture();
      final result = await f.run('inspect');
      final value = (result['value']! as Map).cast<String, Object?>();
      expect(value['phase'], 'preparation-incomplete');
      expect(value['database'], 'stopped');
      expect((value['preparation']! as Map)['stage'], 'services');
      expect(jsonEncode(result).contains('PRIVATE'), isFalse);
      expect(f.calls().every((c) => const ['ps', 'inspect'].contains(c.first)), isTrue);
    },
  );

  test('reset requires explicit discard and never deletes a running or foreign database', () async {
    final f = Fixture();
    expect(await f.run('reset'), fails('discard-data'));
    (f.container['State']! as Map)['Running'] = true;
    f.saveDocker(container: f.container);
    expect(await f.run('discard'), fails('still running'));
    (f.container['State']! as Map)['Running'] = false;
    f.labels['dev.moments.role'] = 'service';
    f.saveDocker(container: f.container);
    expect(await f.run('discard'), fails('does not belong'));
    expect(f.calls().any((c) => c.first == 'rm'), isFalse);
    expect(File(f.manifest).existsSync(), isTrue);
  });

  test('reset preserves proofs and removes only the stopped instance and its recovery state', () async {
    final f = Fixture();
    final proofs = p.join(f.project, 'moments', '.proofs');
    Directory(proofs).createSync();
    File(p.join(proofs, 'prior.json')).writeAsStringSync('evidence');
    for (final name in ['.journey.json', 'ui-session.json']) {
      File(p.join(f.directory, name)).writeAsStringSync('{}');
    }
    final result = await f.run('discard');
    expect((result['value']! as Map)['instanceId'], f.instance['id']);
    expect(f.docker()['container'], isNull);
    expect(File(f.manifest).existsSync(), isFalse);
    expect(File(p.join(f.directory, '.journey.json')).existsSync(), isFalse);
    expect(File(p.join(proofs, 'prior.json')).readAsStringSync(), 'evidence');
    final report = File(p.join(proofs, 'resets', '${f.instance['id']}.json')).readAsStringSync();
    expect(report.contains('PRIVATE'), isFalse);
    expect(report, contains('services'));
    expect(File(p.join(f.directory, '.reset.json')).existsSync(), isFalse);
  });

  test('death after Docker removal retains intent, blocks startup and permits completing the same reset', () async {
    final f = Fixture();
    f.saveDocker(container: f.container, removeThenFail: true);
    expect(await f.run('discard'), fails('operation failed'));
    expect(f.docker()['container'], isNull);
    expect(File(f.manifest).existsSync(), isTrue);
    expect(File(p.join(f.directory, '.reset.json')).existsSync(), isTrue);
    expect(await f.run('lifecycle'), fails('Interrupted reset'));
    expect(await f.run('discard'), succeeds);
    expect(File(f.manifest).existsSync(), isFalse);
    expect(f.calls().where((c) => c.first == 'rm').length, 1);
  });

  test('reset can finish after metadata removal while preserving legacy ownership rules', () async {
    final f = Fixture();
    f.instance.remove('workspace');
    f.labels
      ..remove('dev.moments.workspace')
      ..remove('dev.moments.role');
    f.save();
    f.saveDocker(container: f.container, removeThenFail: true);
    expect((await f.run('discard'))['ok'], false);
    File(f.manifest).deleteSync();
    expect(await f.run('discard'), succeeds);
    expect(File(p.join(f.directory, '.reset.json')).existsSync(), isFalse);
  });

  test('a durable creation intent may have no container, but a ready database cannot silently disappear', () async {
    final f = Fixture();
    f.saveDocker();
    expect(await f.run('find'), fails('missing'));
    expect(await f.run('discard'), fails('missing'));
    f.instance['databasePhase'] = 'creating';
    f.save();
    expect(((await f.run('inspect'))['value']! as Map)['database'], 'not-created');
    expect(await f.run('discard'), succeeds);
    expect(f.calls().any((c) => c.first == 'rm'), isFalse);
  });

  test('reset refuses copied workspace or changed identity before removing resources', () async {
    final f = Fixture();
    f.instance['workspace'] = 'f' * 64;
    f.save();
    expect(await f.run('discard'), fails('another workspace'));
    expect(f.calls(), isEmpty);
  });

  test('Docker failures cannot echo database credentials in diagnostic exceptions', () async {
    final f = Fixture();
    final result = await f.run('docker');
    expect(result, fails('state was preserved'));
    expect(jsonEncode(result).contains('PRIVATE-INPUT'), isFalse);
  });
}
