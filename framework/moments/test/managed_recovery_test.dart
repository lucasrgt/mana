import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/browser.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/managed.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late String program;
  setUpAll(() async {
    await compileCli();
    program = await compileProgram('test/programs/managed_adapters.dart');
  });

  test('session recovery flags and bounded resource declaration refuse ambiguous ownership', () {
    expect(parseArgs(['recover', '--session', 'session']).sessionDirectory, 'session');
    for (final args in [
      ['recover', '--session'],
      ['recover', '--session', 'a', '--run', 'b'],
      ['open', 'root', '--session', 'a'],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
    for (final resources in [
      {
        'processes': ['../foreign'],
        'containers': <String>[],
        'roots': <Object>[],
      },
      {
        'processes': ['runs'],
        'containers': <String>[],
        'roots': <Object>[],
      },
      {
        'processes': ['build'],
        'containers': ['build'],
        'roots': <Object>[],
      },
    ]) {
      expect(() => validateRecoveryResources(resources), throwsA(anything), reason: '$resources');
    }
  });

  test('public recovery cleans a killed session without running adapter code and is repeatable', () async {
    final project = temporary('mana-session-crash-');
    final socket = p.join(project, 'browser.sock');
    final host = await BrowserHost.serve(
      path: socket,
      provider: BrowserProvider(id: 'test', inspect: (id) async => {'id': id, 'status': 'absent'}, close: (_) async {}),
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
      },
      'moments': {
        'root': {
          'projection': {'route': '/'},
          'checks': <Object>[],
          'backend': {'recipe': 'root'},
        },
      },
    });
    final child = await Process.start(
      Platform.resolvedExecutable,
      [
        program,
        'open',
        'root',
        '--isolated',
        '--project',
        project,
        '--browser-socket',
        socket,
        '--browser-provider',
        'test',
        '--json',
      ],
      environment: {'MANA_MOMENTS_ROOT': package},
    );
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    unawaited(child.stderr.drain<void>());
    final ready = await child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.startsWith('{'))
        .map((line) => (jsonDecode(line) as Map).cast<String, Object?>())
        .firstWhere((event) => event['status'] == 'ready')
        .timeout(const Duration(seconds: 60));
    final directory = ready['directory']! as String;
    Future<Run> recover() => moments(['recover', '--session', directory, '--project', project, '--json'], cwd: project);
    // A live owner is rejected before any layer is deleted.
    expect((await recover()).code, 2);
    expect(File(p.join(directory, 'actor-root/actor-state.json')).existsSync(), isTrue);
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
    File(p.join(project, 'moments/adapters.dart')).writeAsStringSync('void main() => throw StateError("adapter ran");');
    late Run result;
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    do {
      result = await recover();
      if (result.code == 0 || !'${result.stdout}${result.stderr}'.contains('operation is running')) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    } while (DateTime.now().isBefore(deadline));
    expect(result.code, 0, reason: result.stdout + result.stderr);
    expect((jsonDecode(result.stdout) as Map)['recipeReplayed'], isFalse);
    expect(File(p.join(directory, 'actor-root/actor-state.json')).existsSync(), isFalse);
    expect(File(p.join(directory, 'mailbox-root/state.json')).existsSync(), isFalse);
    expect(File(p.join(project, 'moments/.backend/materialization.json')).existsSync(), isFalse);
    expect((readJson(p.join(directory, 'session.json'))! as Map)['phase'], 'closed');
    expect((await recover()).code, 0);
  });
}
