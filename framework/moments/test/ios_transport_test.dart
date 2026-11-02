import 'dart:convert';
import 'dart:io';

import 'package:moments/src/flutter_target.dart';
import 'package:moments/src/ios_transport.dart';
import 'package:moments/src/lifecycle.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

const udid = '6C3A1F0E-2B4D-4E5F-8A9B-0C1D2E3F4A5B';

/// A fake `xcrun simctl` with one simulator whose state and boot time tests
/// change.
final class Fixture {
  Fixture() : root = temporary('mana-ios-') {
    claims = p.join(root, 'claims');
    directory = p.join(root, 'one');
  }

  final String root;
  late final String claims, directory;
  var state = 'Booted', booted = '2026-11-01T08:00:00Z', runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-18-2';
  final calls = <List<String>>[];

  String simctl(List<String> args) {
    calls.add(args);
    expect(args, ['list', 'devices', '--json'], reason: 'the transport only reads the inventory');
    return jsonEncode({
      'devices': {
        'com.apple.CoreSimulator.SimRuntime.watchOS-11-2': [
          {'udid': '00000000-0000-0000-0000-000000000000', 'state': 'Booted', 'lastBootedAt': booted},
        ],
        runtime: [
          {'udid': udid, 'state': state, 'name': 'iPhone 16', 'lastBootedAt': booted},
        ],
      },
    });
  }

  IosTransport transport({String? directory, String? owner}) => IosTransport(
    directory: directory ?? this.directory,
    device: udid,
    ports: const [38001, 38002],
    owner: owner,
    simctl: simctl,
    claims: claims,
  );

  Map<String, Object?> journal([String? directory]) =>
      (jsonDecode(File(p.join(directory ?? this.directory, 'transport.json')).readAsStringSync()) as Map).cast();
}

void main() {
  test('the target is selected like Android: an explicit ios:<udid> prefix', () {
    final target = flutterTarget('ios:$udid');
    expect(target.ios, isTrue);
    expect(target.android, isFalse);
    expect(target.args, ['-d', udid]);
    expect(flutterTarget('macos').args, ['-d', 'macos']);
    for (final device in ['ios:', 'ios:iPhone 16', 'ios:${udid.toLowerCase()}']) {
      expect(() => flutterTarget(device), throwing('Supported Moments devices'));
    }
  });

  test('a booted simulator is claimed by one run; a second run is refused without being used', () async {
    final f = Fixture();
    final state = await f.transport().start();
    expect(state['phase'], 'ready');
    expect(state['runtime'], contains('.iOS-'));
    expect(f.journal()['phase'], 'ready');
    final other = f.transport(directory: p.join(f.root, 'two'));
    await expectLater(other.start(), throwing('claimed by another run'));
    expect(f.journal(p.join(f.root, 'two'))['phase'], 'planned');
    expect(Directory(f.claims).listSync(), hasLength(1));
  });

  test('closing releases the claim for the next run; the journal records disposal', () async {
    final f = Fixture();
    final transport = f.transport();
    await transport.start();
    expect((await transport.close())['phase'], 'disposed');
    expect(Directory(f.claims).listSync(), isEmpty);
    expect((await f.transport(directory: p.join(f.root, 'two')).start())['phase'], 'ready');
  });

  test('a shut down, missing or non-iOS simulator is refused before any claim', () async {
    final f = Fixture()..state = 'Shutdown';
    await expectLater(f.transport().start(), throwing('A booted iOS simulator is required'));
    f
      ..state = 'Booted'
      ..runtime = 'com.apple.CoreSimulator.SimRuntime.tvOS-18-2';
    await expectLater(f.transport(directory: p.join(f.root, 'tv')).start(), throwing('A booted iOS simulator'));
    expect(Directory(f.claims).listSync(), isEmpty);
    final missing = IosTransport(
      directory: p.join(f.root, 'missing'),
      device: '11111111-2222-4333-8444-555555555555',
      ports: const [38001],
      simctl: f.simctl,
      claims: f.claims,
    );
    await expectLater(missing.start(), throwing('No iOS simulator with that UDID'));
  });

  test('a claim from an earlier boot of the same simulator does not hold it after a reboot', () async {
    final f = Fixture();
    await f.transport().start();
    f.booted = '2026-11-01T09:30:00Z';
    final next = await f.transport(directory: p.join(f.root, 'two')).start();
    expect(next['phase'], 'ready');
    expect(next['boot'], isNot(f.journal()['boot']));
  });

  test('recovery after the supervisor died releases the claim; a live supervisor refuses it', () async {
    final f = Fixture();
    await f.transport().start();
    await expectLater(recoverIosTransport(f.directory, simctl: f.simctl, claims: f.claims), throwing('still alive'));
    final journal = f.journal();
    // A supervisor that is gone: same pid, another start.
    savePrivateJournal(p.join(f.directory, 'transport.json'), {
      ...journal,
      'supervisor': {...(journal['supervisor']! as Map), 'start': '1'},
    });
    expect((await recoverIosTransport(f.directory, simctl: f.simctl, claims: f.claims))['phase'], 'disposed');
    expect(Directory(f.claims).listSync(), isEmpty);
  });

  test('lifecycle version 3 records the simulator, refused in version 2 or beside Android', () {
    final project = temporary('mana-ios-life-'), directory = p.join(project, 'moments/.backend');
    Directory(directory).createSync(recursive: true);
    final life = Lifecycle.create(
      project: project,
      directory: directory,
      ports: const [38001, 38002],
      ios: const {
        'device': udid,
        'ports': [38001, 38002],
      },
    );
    addTearDown(life.finish);
    expect(life.state['version'], 3);
    final valid = validateLifecycle(life.state, project);
    expect(valid['ios'], isNotNull);
    expect(() => validateLifecycle({...life.state, 'version': 2}, project), throwing('requires lifecycle version 3'));
    expect(
      () => validateLifecycle({
        ...life.state,
        'android': {
          'device': 'emulator-5554',
          'ports': [38001],
        },
      }, project),
      throwing('Invalid iOS simulator lifecycle ownership'),
    );
    expect(
      () => validateLifecycle({
        ...life.state,
        'ios': {
          'device': udid,
          'ports': [9],
        },
      }, project),
      throwing('Invalid iOS simulator lifecycle ownership'),
    );
  });
}

void savePrivateJournal(String file, Map<String, Object?> value) {
  File(file).writeAsStringSync(jsonEncode(value));
}
