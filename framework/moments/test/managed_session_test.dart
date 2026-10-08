import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/browser.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/composition.dart';
import 'package:moments/src/layers.dart';
import 'package:moments/src/lifecycle.dart';
import 'package:moments/src/managed.dart';
import 'package:moments/src/materializer.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

final class Memory implements LayerDriver {
  Memory(this.profile);
  final Profile profile;

  @override
  String get type => 'memory';
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
  }) async {
    if (profile.live > 0) throw StateError('Captured live actor');
  }

  @override
  Future<void> dispose({required LayerHandle handle, LayerOptions opts = const LayerOptions()}) async =>
      profile.note('dispose');
  @override
  Future<void> forget({required String dir, LayerOptions opts = const LayerOptions()}) async => profile.note('forget');
  @override
  Future<Map<String, Object?>> recover({
    required String dir,
    LayerOptions opts = const LayerOptions(),
    bool pending = false,
  }) => throw StateError('No recovery in this fixture');
}

final class Runtime implements MaterializerRuntime {
  Runtime(this.profile);
  final Profile profile;

  @override
  String get type => 'memory';
  @override
  Object allocate(World world) => {'url': 'http://example.invalid'};
  @override
  Future<void> start(Object handle, World world) async => profile.live++;
  @override
  Future<void> stop(Object handle) async {
    if (profile.mode == 'stop-fails' && profile.transitions > 0) throw StateError('Closure unconfirmed');
    profile.live--;
    profile.note('stop');
  }

  @override
  Null get executeJourney => null;
}

final class Profile implements MaterializationProfile {
  Profile(this.events, this.mode);
  final List<String> events;
  final String mode;
  var live = 0, transitions = 0;

  void note(String event) => events.add(event);

  @override
  late final engine = MaterializationEngine(
    scope: 'Mechanism only, no browser or app execution',
    layers: [(name: 'memory', driver: Memory(this), root: 'initial', opts: const LayerOptions())],
    recipes: {
      'root': (_) async {
        note('transition');
        transitions++;
      },
    },
    runtime: Runtime(this),
  );

  @override
  Map<String, Object?> get recovery => {'processes': <String>[], 'containers': <String>[], 'roots': <Object>[]};

  @override
  String codeIdentity() => 'a' * 64;

  @override
  Future<void> prepare({
    required Interruption signal,
    required void Function(Map<String, Object?> event) onProgress,
  }) async {
    note('prepare');
    if (mode != 'prepare-waits') return;
    final aborted = Completer<void>();
    signal.onAbort(aborted.complete);
    await aborted.future;
  }

  @override
  Future<void> cleanup() async {
    if (live > 0) throw StateError('Roots discarded with live actor');
    note('roots-cleaned');
  }
}

final class Fixture {
  Fixture._(this.project, this.socket, this.events, this.adapters);
  final String project, socket;
  final List<String> events;
  final ProjectAdapters adapters;
  final name = 'root', provider = 'test';
  String get lifecycle => p.join(project, 'moments/.backend');

  static Future<Fixture> create([String mode = 'normal']) async {
    final project = temporary('mana-managed-');
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
    final events = <String>[];
    return Fixture._(project, socket, events, ProjectAdapters(materialization: (_) => Profile(events, mode)));
  }

  Future<ManagedSession> open({int copies = 1, String? device, bool host = true, Interruption? signal}) =>
      openManagedSession(
        project: project,
        name: name,
        adapters: adapters,
        copies: copies,
        device: device,
        browserSocket: host ? socket : null,
        browserProvider: host ? provider : null,
        signal: signal,
      );

  Future<int> serve(void Function(Map<String, Object?> value) emit, Interruption interruption) => serveManagedSession(
    project: project,
    name: name,
    adapters: adapters,
    copies: 1,
    browserSocket: socket,
    browserProvider: provider,
    emit: emit,
    interruption: interruption,
  );
}

void main() {
  test('managed CLI rejects missing host and ambiguous or misplaced options', () {
    const host = ['--browser-socket', '/private/browser.sock', '--browser-provider', 'test'];
    expect(parseArgs(['fork', 'root', ...host]).command, 'fork');
    expect(parseArgs(['open', 'root', '--isolated', ...host]).isolated, isTrue);
    for (final args in [
      ['fork', 'root'],
      ['fork', ...host],
      ['open', 'root', '--isolated', '--fresh', ...host],
      ['check', 'root', '--isolated'],
      ['open', 'root', '--copies', '2', ...host],
      ['fork', 'root', '--copies', '9', ...host],
      ['fork', 'root', '--copies', '2', '--copies', '3', ...host],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
  });

  test('Android selection is explicit, single-actor and cannot silently become a browser run', () async {
    const args = ['open', 'root', '--isolated', '--device', 'android:emulator-5554'];
    expect(parseArgs(args).device, 'android:emulator-5554');
    expect(
      () => parseArgs([...args, '--browser-socket', '/tmp/host', '--browser-provider', 'test']),
      throwing('Isolated Android'),
    );
    expect(() => parseArgs(['fork', 'root', '--device', 'android:emulator-5554']), throwing('device'));
    final f = await Fixture.create();
    await expectLater(f.open(device: 'android:emulator-5554'), throwing('one actor'));
    await expectLater(f.open(device: 'android:emulator-5554', copies: 2, host: false), throwing('one actor'));
    await expectLater(f.open(device: 'android:emulator-5554', host: false), throwing('does not support Android'));
    expect(f.events, isNot(contains('prepare')));
  });

  test('two managed actors share one transition; close orders actors before roots and is idempotent', () async {
    final f = await Fixture.create();
    final session = await f.open(copies: 2);
    final actors = (session.ready['actors']! as List).cast<Map<String, Object?>>();
    expect(actors, hasLength(2));
    expect(actors[0]['id'], isNot(actors[1]['id']));
    expect(actors.map((a) => a['url']), everyElement('http://example.invalid'));
    expect(f.events.where((e) => e == 'transition'), hasLength(1));
    await expectLater(f.open(), throwing('operation is running'));
    await expectLater(withInstanceLock(f.lifecycle, () async {}), throwing('operation is running'));
    await Future.wait([session.close(), session.close()]);
    await session.close();
    expect(f.events.last, 'roots-cleaned');
    expect(f.events.where((e) => e == 'roots-cleaned'), hasLength(1));
    expect((readJson(p.join(session.ready['directory']! as String, 'session.json'))! as Map)['phase'], 'closed');
    await withInstanceLock(f.lifecycle, () async => assertNoManagedSession(f.lifecycle));
  });

  test('interruption during preparation waits for cleanup', () async {
    final f = await Fixture.create('prepare-waits');
    final interruption = Interruption();
    await expectLater(
      f.serve((event) {
        if (event['phase'] == 'preparing') Timer.run(interruption.abort);
      }, interruption),
      throwing('interrupted'),
    );
    expect(f.events, ['prepare', 'roots-cleaned']);
  });

  test('ready session closes on termination, with explicit final receipt', () async {
    final f = await Fixture.create();
    final interruption = Interruption(), events = <Map<String, Object?>>[];
    final code = await f.serve((event) {
      events.add(event);
      if (event['status'] == 'ready') interruption.abort();
    }, interruption);
    expect(code, 0);
    expect(events.last['status'], 'closed');
    expect(f.events.last, 'roots-cleaned');
  });

  test('unconfirmed actor closure retains roots and records attention instead of success', () async {
    final f = await Fixture.create('stop-fails');
    await expectLater(f.open(), throwing('needs inspection'));
    expect(f.events, isNot(contains('roots-cleaned')));
    expect(f.events, isNot(contains('dispose')));
    final home = Directory(p.join(f.project, 'moments/.proofs/materializations'));
    final session = home.listSync().single.path;
    expect((jsonDecode(File(p.join(session, 'session.json')).readAsStringSync()) as Map)['phase'], 'attention');
    await expectLater(f.open(), throwing('session owns'));
  });
}
