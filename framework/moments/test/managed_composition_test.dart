import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/browser.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/composition.dart';
import 'package:moments/src/managed.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'programs/managed_adapters.dart';
import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

final class Fixture {
  Fixture._(this.project, this.planFile, this.socket, this.mode);
  final String project, planFile, socket, mode;
  var closed = 0;
  ProjectAdapters get adapters => ProjectAdapters(composition: (context) => TestComposition(context, mode));
  List<String> get events => File(p.join(project, 'events')).readAsStringSync().trim().split('\n');
  Map<String, Object?> session(Map<String, Object?> result) =>
      (readJson(p.join(result['directory']! as String, 'session.json'))! as Map).cast();

  static Future<Fixture> create([String mode = 'normal']) async {
    final project = temporary('mana-compose-');
    Map<String, Object?>? tab;
    late Fixture fixture;
    final socket = p.join(project, 'browser.sock');
    final host = await BrowserHost.serve(
      path: socket,
      openOrigins: const ['http://127.0.0.1:54321'],
      provider: BrowserProvider(
        id: 'test',
        open: (url) async => tab = {'id': 'owned', 'url': url, 'status': 'present'},
        find: (url) async => {
          'matches': [if (tab != null && tab!['url'] == url && tab!['status'] == 'present') tab],
        },
        inspect: (id) async => {...?tab, 'id': id},
        close: (_) async {
          tab!['status'] = 'absent';
          fixture.closed++;
        },
      ),
    );
    addTearDown(host.close);
    writeJson(p.join(project, 'moments/manifest.json'), {
      'version': 3,
      'protocol': protocol,
      'watch': <Object>[],
      'properties': {
        'route': {
          'enum': ['/'],
        },
        'phase': {'restore': false},
      },
      'moments': {
        'root': {
          'projection': {'route': '/'},
          'checks': [
            {'name': 'ready', 'kind': 'ui_equals', 'field': 'phase', 'equals': 'ready'},
          ],
        },
      },
    });
    final planFile = p.join(project, 'plan.json');
    writeJson(planFile, {
      'version': 1,
      'stages': [
        {'id': 'check', 'surface': 'a', 'moment': 'root', 'kind': 'checkpoint'},
      ],
    });
    return fixture = Fixture._(project, planFile, socket, mode);
  }

  Future<Map<String, Object?>> run([ProjectAdapters? adapters]) => runManagedComposition(
    project: project,
    planFile: planFile,
    profile: 'test',
    browserSocket: socket,
    browserProvider: 'test',
    adapters: adapters ?? this.adapters,
  );
}

void main() {
  late String program;
  setUpAll(() async {
    await compileCli();
    program = await compileProgram('test/programs/managed_adapters.dart');
  });

  test('compose CLI requires an explicit profile, plan and paired browser host', () {
    const args = [
      'compose',
      '--plan',
      'plan.json',
      '--profile',
      'local',
      '--browser-socket',
      'host.sock',
      '--browser-provider',
      'test',
    ];
    expect(parseArgs(args).command, 'compose');
    for (final bad in [
      args.sublist(0, args.length - 2),
      args.sublist(0, 3),
      [...args, 'extra'],
      ['run', 'root', '--profile', 'local'],
      [...args, '--evidence', 'x'],
      [...args, '--fresh'],
    ]) {
      expect(() => parseArgs(bad), throwsA(anything), reason: '$bad');
    }
    for (final browsers in [
      ['../other'],
      ['runs'],
      ['same', 'same'],
    ]) {
      expect(
        () => validateRecoveryResources({
          'processes': <String>[],
          'containers': <String>[],
          'roots': <Object>[],
          'browsers': browsers,
        }),
        throwsA(anything),
      );
    }
  });

  test('public composition records a checkpoint and closes its ownership boundary', () async {
    final f = await Fixture.create(), r = await f.run();
    expect(r['exitCode'], 0);
    expect(r['resourcesClosed'], isTrue);
    expect((((r['composition']! as Map)['stages']! as List).first as Map)['status'], 'passed');
    expect(f.events.last, 'cleanup');
    expect(File(p.join(f.project, 'moments/.backend/materialization.json')).existsSync(), isFalse);
    expect(f.session(r)['phase'], 'closed');
  });

  test('preparation failure is cleaned without leaking private adapter errors', () async {
    final f = await Fixture.create('prepare-fails'), r = await f.run();
    expect(r['exitCode'], 2);
    expect(f.events, ['prepare', 'cleanup']);
    expect(jsonEncode(r), isNot(contains('private-input')));
  });

  test('unconfirmed cleanup retains the ownership marker for explicit recovery', () async {
    final f = await Fixture.create('cleanup-fails'), r = await f.run();
    expect(r['exitCode'], 2);
    expect(r['resourcesClosed'], isFalse);
    expect(jsonEncode(r), isNot(contains('private-cleanup')));
    expect(f.session(r)['phase'], 'attention');
    await expectLater(f.run(), throwing('session owns'));
  });

  test('interruption during prepare prevents observations and still waits for cleanup', () async {
    final f = await Fixture.create('wait'), interruption = Interruption();
    final r = await serveManagedComposition(
      project: f.project,
      planFile: f.planFile,
      profile: 'test',
      browserSocket: f.socket,
      browserProvider: 'test',
      adapters: f.adapters,
      interruption: interruption,
      emit: (event) {
        if (event['phase'] == 'preparing') Timer.run(interruption.abort);
      },
    );
    expect(r['exitCode'], 2);
    expect(f.events, ['prepare', 'cleanup']);
  });

  test('invalid complete plan is rejected before allocating the adapter', () async {
    final f = await Fixture.create();
    final plan = (readJson(f.planFile)! as Map).cast<String, Object?>();
    final stages = plan['stages']! as List;
    stages.add({...(stages.first as Map), 'id': 'bad', 'moment': 'missing'});
    writeJson(f.planFile, plan);
    await expectLater(
      f.run(ProjectAdapters(composition: (_) => throw StateError('adapter was allocated'))),
      throwing('unknown Moment'),
    );
    expect(Directory(p.join(f.project, 'moments/.backend')).existsSync(), isFalse);
  });

  test('killed composition recovers owned browser through public CLI without adapter code or replay', () async {
    final f = await Fixture.create('crash');
    final child = await Process.start(
      Platform.resolvedExecutable,
      [
        program,
        'compose',
        '--plan',
        f.planFile,
        '--profile',
        'test',
        '--project',
        f.project,
        '--browser-socket',
        f.socket,
        '--browser-provider',
        'test',
        '--json',
      ],
      environment: {'MANA_MOMENTS_ROOT': package, 'MANA_TEST_MODE': 'crash'},
    );
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    unawaited(child.stderr.drain<void>());
    final ready = await child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
        .firstWhere((event) => event['phase'] == 'executing')
        .timeout(const Duration(seconds: 60));
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
    // Recovery must never run the project's program.
    File(
      p.join(f.project, 'moments/adapters.dart'),
    ).writeAsStringSync('void main() => throw StateError("adapter ran");');
    Future<Run> recover({bool host = false}) => moments([
      'recover',
      '--session',
      ready['directory']! as String,
      '--project',
      f.project,
      '--json',
      if (host) ...['--browser-socket', f.socket, '--browser-provider', 'test'],
    ], cwd: f.project);
    late Run r;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    do {
      r = await recover();
      if (!'${r.stdout}${r.stderr}'.contains('operation is running')) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } while (DateTime.now().isBefore(deadline));
    expect(r.code, 2, reason: r.stderr);
    expect(f.closed, 0);
    r = await recover(host: true);
    expect(r.code, 0, reason: r.stdout + r.stderr);
    expect(f.closed, 1);
    final result = jsonDecode(r.stdout) as Map;
    expect(result['recipeReplayed'], isFalse);
    expect(result['browsers'], ['surface']);
    expect((await recover()).code, 0);
    expect(f.closed, 1);
    expect(f.events.where((e) => e == 'prepare'), ['prepare']);
  });
}
