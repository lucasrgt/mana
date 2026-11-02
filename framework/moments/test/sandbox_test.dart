import 'dart:io';

import 'package:moments/src/adapter.dart';
import 'package:moments/src/preparation_retry.dart';
import 'package:moments/src/sandbox.dart';
import 'package:moments/src/services.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher refusing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

const _journeyId = '00000000-0000-4000-8000-000000000001';
const _instanceId = '00000000-0000-4000-8000-000000000002';

/// An app with one `inbox` Moment backed by the `inbox` recipe. Every refusal
/// below happens before `runSandbox` owns anything (no `running.json`, no
/// Docker, no Flutter), which each test also checks.
final class App {
  App({Map<String, Object?> ports = const {'web': 0, 'bridge': 0, 'api': 0}}) : root = temporary('moments-sandbox-') {
    File(p.join(root, 'lib/app.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}');
    writeJson(p.join(root, 'moments/manifest.json'), {
      'version': 1,
      'watch': ['lib/app.dart'],
      'properties': {
        'route': {
          'enum': ['/tasks'],
        },
      },
      'moments': {
        'inbox': {
          'projection': {'route': '/tasks'},
          'backend': {'recipe': 'inbox'},
        },
      },
    });
    writeJson(p.join(root, 'moments/backend.json'), {'version': 1, 'name': 'inbox', 'ports': ports});
  }

  final String root;
  String get directory => p.join(root, 'moments/.backend');
  String file(String name) => p.join(directory, name);

  void instance(Map<String, Object?> value) => writeJson(file('instance.json'), value);
  void journey() => writeJson(file('.journey.json'), {
    'version': 1,
    'lease': {'id': _journeyId, 'name': 'inbox', 'phase': 'attention', 'expiresAt': 0},
  });

  Future<void> run(String operation, [SandboxOptions options = const SandboxOptions()]) =>
      runSandbox(Adapter.load(root), operation, options: options);

  void expectNothingOwned() {
    expect(File(file('running.json')).existsSync(), isFalse);
    expect(File(file('.operation.lock')).existsSync(), isFalse);
  }
}

ServiceDefinition _service({List<String>? prepare, bool idempotent = false}) => ServiceDefinition(
  name: 'api',
  cwd: '.',
  port: 4000,
  prepare: prepare,
  serve: const ['serve'],
  prepareIdempotent: idempotent,
  ready: () async => true,
);

void main() {
  group('runSandbox refuses before owning anything', () {
    test('--backend-only with a native device', () async {
      final app = App();
      await expectLater(
        app.run('up', const SandboxOptions(backendOnly: true, device: 'linux')),
        refusing('--backend-only serves web suites'),
      );
      app.expectNothingOwned();
    });

    test('an unsupported device', () async {
      final app = App();
      await expectLater(app.run('up', const SandboxOptions(device: 'ios')), refusing('Supported Moments devices'));
    });

    test('look without an instance', () async {
      final app = App();
      await expectLater(app.run('look'), refusing('Run moment up first'));
    });

    test('look at an instance whose container does not match its id', () async {
      final app = App()..instance({'id': _instanceId, 'container': 'someone-else'});
      await expectLater(app.run('look'), refusing('Invalid sandbox database identity'));
    });

    for (final operation in ['up', 'reset']) {
      test('$operation while a run record exists, leaving the record untouched', () async {
        final app = App();
        writeJson(app.file('running.json'), {'marker': true});
        final before = File(app.file('running.json')).readAsStringSync();
        await expectLater(app.run(operation), refusing('Moment already running (or interrupted)'));
        expect(File(app.file('running.json')).readAsStringSync(), before);
      });
    }

    test('an unknown operation', () async {
      final app = App();
      await expectLater(app.run('start'), refusing('Expected up, look or reset'));
      app.expectNothingOwned();
    });

    test('a busy bridge port', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(busy.close);
      final app = App(ports: {'web': 0, 'api': 0, 'bridge': busy.port});
      await expectLater(app.run('up'), refusing('Port ${busy.port} is already in use'));
      app.expectNothingOwned();
    });

    test('a busy web port, but not with --backend-only, which serves no web runtime', () async {
      final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(busy.close);
      final app = App(ports: {'web': busy.port, 'api': 0, 'bridge': 0})
        ..instance({'phase': 'seeding', 'id': _instanceId});
      await expectLater(app.run('up'), refusing('Port ${busy.port} is already in use'));
      // Past the port check, the next refusal is the interrupted seeding.
      await expectLater(
        app.run('up', const SandboxOptions(backendOnly: true)),
        refusing('Previous base preparation was interrupted'),
      );
      app.expectNothingOwned();
    });

    test('a base seeding that never committed a launch', () async {
      final app = App()..instance({'phase': 'seeding', 'id': _instanceId});
      await expectLater(app.run('up'), refusing('Previous base preparation was interrupted'));
      app.expectNothingOwned();
    });

    test('an interrupted journey without a committed base', () async {
      final app = App()
        ..instance({'phase': 'creating', 'id': _instanceId})
        ..journey();
      await expectLater(app.run('up'), refusing('Interrupted journey has no committed base'));
      app.expectNothingOwned();
    });

    test('fresh data over an interrupted journey', () async {
      final app = App()
        ..instance({
          'phase': 'ready',
          'id': _instanceId,
          'launch': {'route': '/tasks'},
        })
        ..journey();
      await expectLater(
        app.run('up', const SandboxOptions(fresh: true)),
        refusing('An interrupted journey must be inspected and recovered'),
      );
      app.expectNothingOwned();
    });

    test('a stored launch prepared for another Moment, naming --fresh as the explicit replacement', () async {
      final app = App()
        ..instance({
          'phase': 'ready',
          'id': _instanceId,
          'launch': {'route': '/tasks'},
          'preparedMoment': {'name': 'other'},
        });
      await expectLater(app.run('up'), refusing('Stored preparation does not identify inbox'));
      await expectLater(app.run('up'), refusing('moments up inbox --fresh'));
      app.expectNothingOwned();
    });

    test('an incomplete preparation without --retry-preparation', () async {
      final app = App()
        ..instance({
          'phase': 'ready',
          'id': _instanceId,
          'launch': {'route': '/tasks'},
          'preparation': {'moment': 'inbox', 'stage': 'recipe'},
        });
      await expectLater(app.run('up'), refusing('Previous startup preparation is incomplete'));
      app.expectNothingOwned();
    });

    test('--retry-preparation with nothing to retry', () async {
      final app = App();
      await expectLater(
        app.run('up', const SandboxOptions(retryPreparation: true)),
        refusing('No interrupted service preparation to retry'),
      );
      app.expectNothingOwned();
    });
  });

  group('validatePreparationRetry', () {
    Map<String, Object?> interrupted({String stage = 'services', String moment = 'inbox'}) => {
      'phase': 'ready',
      'launch': {'route': '/tasks'},
      'preparation': {'moment': moment, 'stage': stage},
    };
    void retry(Map<String, Object?>? instance, List<ServiceDefinition> services, {Map<String, Object?>? journey}) =>
        validatePreparationRetry(
          instance,
          retryPreparation: true,
          initialMoment: 'inbox',
          services: services,
          journey: journey,
        );

    test('repeats services on the same committed base when every preparation is idempotent', () {
      retry(interrupted(), [
        _service(prepare: ['migrate'], idempotent: true),
      ]);
      retry(interrupted(), [_service()]);
    });

    test('never replays a base or recipe stage, another Moment or an interrupted journey', () {
      final services = [
        _service(prepare: ['migrate'], idempotent: true),
      ];
      const reason = 'Only interrupted services on the same committed base and Moment';
      expect(() => retry(interrupted(stage: 'recipe'), services), refusing(reason));
      expect(() => retry(interrupted(stage: 'base'), services), refusing(reason));
      expect(() => retry(interrupted(moment: 'other'), services), refusing(reason));
      expect(() => retry({...interrupted(), 'launch': null}, services), refusing(reason));
      expect(() => retry({...interrupted(), 'phase': 'seeding'}, services), refusing(reason));
      expect(() => retry(interrupted(), services, journey: {'id': _journeyId}), refusing(reason));
    });

    test('refuses a preparation not declared idempotent, or no services at all', () {
      const reason = 'prepareIdempotent: true';
      expect(
        () => retry(interrupted(), [
          _service(prepare: ['migrate']),
        ]),
        refusing(reason),
      );
      expect(() => retry(interrupted(), []), refusing(reason));
    });

    test('a clean instance passes without the flag', () {
      validatePreparationRetry({'phase': 'ready'}, retryPreparation: false, initialMoment: 'inbox', services: const []);
      validatePreparationRetry(null, retryPreparation: false, initialMoment: 'inbox', services: const []);
    });
  });
}
