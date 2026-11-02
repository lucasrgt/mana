import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:mana/runtime.dart' show identityJson;
import 'package:moments/src/lifecycle.dart';
import 'package:moments/src/suite.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher refusing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// Thrown from `onEvent` to stop [runSuite] at a decision, before it starts
/// a backend, a build or a browser.
final class _Stop implements Exception {
  const _Stop(this.event);
  final Map<String, Object?> event;
}

/// An app with the `inbox` and `done` Moments.
final class App {
  App() : root = temporary('moments-suite-') {
    File(p.join(root, 'lib/app.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    final declaration = File(p.join(root, 'moments/declaration.exs'))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Moments\n');
    final source = {'file': 'declaration.exs', 'sha256': '${sha256.convert(declaration.readAsBytesSync())}'};
    writeJson(p.join(root, 'moments/manifest.json'), {
      'version': 1,
      'watch': ['lib/app.dart'],
      'properties': {
        'route': {
          'enum': ['/tasks'],
        },
      },
      'moments': {
        for (final name in ['inbox', 'done'])
          name: {
            'projection': {'route': '/tasks'},
            'backend': {'recipe': name},
            'source': source,
          },
      },
    });
    writeJson(p.join(root, 'moments/backend.json'), {
      'version': 1,
      'name': 'inbox',
      'ports': {'web': 0, 'bridge': 0, 'api': 0},
    });
  }

  final String root;
  String get directory => p.join(root, 'moments/.backend');

  void git() {
    for (final args in [
      ['init', '-q'],
      ['add', '.'],
      ['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'base'],
    ]) {
      final result = Process.runSync('git', args, workingDirectory: root);
      if (result.exitCode != 0) throw StateError('git ${args.first}: ${result.stderr}');
    }
  }

  /// A `running.json` that passes ownership validation, for [supervisor].
  void running(Map<String, Object?> supervisor) => writeJson(p.join(directory, 'running.json'), {
    'version': 2,
    'runId': '00000000-0000-4000-8000-000000000001',
    'instanceId': '00000000-0000-4000-8000-000000000002',
    'workspace': workspaceIdentity(root),
    'supervisor': supervisor,
    'ports': <int>[],
    'databaseStarted': false,
    'processes': <Object?>[],
  });

  /// The first event in [phases], after which the suite is stopped.
  Future<Map<String, Object?>> stopAt(
    List<String> phases, {
    List<String>? names,
    String? affectedBase,
    int workers = 4,
    List<String>? seen,
  }) async {
    try {
      await runSuite(
        project: root,
        names: names,
        workers: workers,
        affectedBase: affectedBase,
        onEvent: (event) {
          seen?.add(event['phase']! as String);
          if (phases.contains(event['phase'])) throw _Stop(event);
        },
      );
    } on _Stop catch (stop) {
      return stop.event;
    }
    fail('the suite never reached $phases');
  }
}

void main() {
  test('selfCommand runs this same program again', () {
    final command = selfCommand();
    expect(command.first, Platform.resolvedExecutable);
    expect(command.length, Platform.script.toFilePath().endsWith('.dart') ? 2 : 1);
  });

  group('runSuite refuses before starting anything', () {
    test('an unknown build mode or runtime', () async {
      final app = App();
      await expectLater(runSuite(project: app.root, mode: 'release'), refusing('profile, debug or wasm'));
      await expectLater(runSuite(project: app.root, runtime: 'android'), refusing('browser or headless'));
    });

    test('a project without a Moments adapter', () async {
      final root = temporary();
      await expectLater(runSuite(project: root), refusing('Missing Moments adapter'));
    });

    test('an unknown Moment', () async {
      final app = App();
      await expectLater(runSuite(project: app.root, names: ['inbox', 'missing']), refusing('Unknown Moment: missing'));
    });

    test('a worker count outside 1–8', () async {
      final app = App();
      for (final workers in [0, 9]) {
        await expectLater(runSuite(project: app.root, workers: workers), refusing('Use 1–8 workers'));
      }
    });

    test('named Moments together with --affected', () async {
      final app = App()..git();
      await expectLater(
        runSuite(project: app.root, names: ['inbox'], affectedBase: 'HEAD'),
        refusing('Choose named Moments or --affected, not both'),
      );
    });

    test('--affected outside a Git checkout', () async {
      final app = App();
      await expectLater(runSuite(project: app.root, affectedBase: 'HEAD'), refusing('A valid Git checkout'));
    });

    test('nothing is written under the project by a refusal', () async {
      final app = App();
      await expectLater(runSuite(project: app.root, workers: 0), throwsA(anything));
      expect(Directory(app.directory).existsSync(), isFalse);
      expect(Directory(p.join(app.root, 'moments/.suite')).existsSync(), isFalse);
    });
  });

  group('runSuite --affected', () {
    test('runs the whole catalog when no green suite recorded the framework', () async {
      final app = App()..git();
      final event = await app.stopAt(['affected'], affectedBase: 'HEAD');
      expect(event['precision'], 'whole-catalog');
      expect(event['reason'], contains('Mana framework changed'));
      expect(event['moments'], 2);
    });

    test('runs the whole catalog when the framework changed since the last green suite', () async {
      final app = App()..git();
      writeJson(p.join(app.root, 'moments/.suite/framework.json'), {'digest': 'older', 'at': '2026-01-01T00:00:00Z'});
      final event = await app.stopAt(['affected'], affectedBase: 'HEAD');
      expect(event['precision'], 'whole-catalog');
      expect(event['reason'], contains('Mana framework changed'));
      expect(event['moments'], 2);
    });

    test('runs the whole catalog when the plan is unavailable (a declaration out of sync)', () async {
      final app = App()..git();
      File(p.join(app.root, 'moments/declaration.exs')).writeAsStringSync('# edited after sync\n');
      final event = await app.stopAt(['affected'], affectedBase: 'HEAD');
      expect(event['precision'], 'whole-catalog');
      expect(event['reason'], 'affected plan unavailable');
      expect(event['moments'], 2);
    });
  });

  group('runSuite backend', () {
    test('starts a temporary backend when none is running', () async {
      final app = App();
      final seen = <String>[];
      await app.stopAt(['backend'], seen: seen);
      expect(seen, ['backend']);
    });

    test('recovers a run whose supervisor is gone before trusting its backend', () async {
      final app = App();
      final self = identityJson(processIdentity(pid)!);
      // Same pid and boot, another start time: a process that no longer exists.
      app.running({...self, 'start': '${self['start']}0'});
      final seen = <String>[];
      await app.stopAt(['recover', 'backend'], seen: seen);
      expect(seen, ['recover']);
    });

    test('does not recover a live run; a missing runtime record still needs a backend', () async {
      final app = App();
      app.running(identityJson(processIdentity(pid)!));
      final seen = <String>[];
      await app.stopAt(['recover', 'backend'], seen: seen);
      expect(seen, ['backend']);
    });

    test('refuses a run record without valid ownership', () async {
      final app = App();
      writeJson(p.join(app.directory, 'running.json'), {'version': 2});
      await expectLater(runSuite(project: app.root), refusing('no valid recovery ownership'));
    });
  });
}
