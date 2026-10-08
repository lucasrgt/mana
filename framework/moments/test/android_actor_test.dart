import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState;
import 'package:moments/src/android_actor.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/owned_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// A dedicated emulator whose app processes, users and reverse ports are
/// switches the test flips.
final class Fixture {
  Fixture() : root = temporary('mana-native-actor-') {
    directory = p.join(root, 'actor');
    claims = p.join(root, 'claims');
    Directory(directory).createSync();
    Process.runSync('chmod', ['700', directory]);
    actor = make();
  }

  static const applicationId = 'dev.mana.fixture', device = 'emulator-5554', ports = [38001, 38002];
  final String root;
  late final String directory, claims;
  late final AndroidActor actor;
  final forwards = <String, String>{};
  final calls = <List<String>>[];
  var boot = '10000000-0000-4000-8000-000000000001', online = true, running = false, multi = false, stubborn = false;

  AndroidActor make() => AndroidActor(
    directory: directory,
    device: device,
    applicationId: applicationId,
    ports: ports,
    adb: adb,
    claims: claims,
  );

  String adb(List<String> args) {
    calls.add(args);
    expect(args.sublist(0, 2), ['-s', device]);
    if (!online) throw const MomentsError('offline');
    final command = args.skip(2).join(' ');
    if (command == 'shell cat /proc/sys/kernel/random/boot_id') return boot;
    if (command == 'shell getprop ro.build.version.sdk') return '36';
    if (command == 'shell pm list users')
      return 'Users:\n UserInfo{0:Owner:13} running${multi ? '\n UserInfo{10:Guest:10}' : ''}';
    if (command == 'shell am get-current-user') return '0';
    if (command == 'shell ps -A -o PID,NAME') {
      return '  PID NAME\n 1 init\n 40 another.app\n${running ? ' 50 $applicationId\n 51 $applicationId:worker' : ''}';
    }
    if (command == 'shell am force-stop --user 0 $applicationId') {
      if (!stubborn) running = false;
      return '';
    }
    if (args[2] == 'reverse') {
      if (args[3] == '--list')
        return [for (final MapEntry(:key, :value) in forwards.entries) 'host $key $value'].join('\n');
      if (args[3] == '--no-rebind') {
        expect(forwards.containsKey(args[4]), isFalse);
        forwards[args[4]] = args[5];
        return '';
      }
      if (args[3] == '--remove') {
        forwards.remove(args[4]);
        return '';
      }
    }
    fail('Unexpected Android command $args');
  }

  Map<String, Object?> record(String name) => (readJson(p.join(directory, name))! as Map).cast();
  void dead() {
    for (final name in ['transport.json', 'android-app.json']) {
      final value = record(name);
      value['supervisor'] = {...(value['supervisor']! as Map).cast<String, Object?>(), 'pid': 2147483647};
      savePrivateState(p.join(directory, name), value);
    }
  }

  int stops() => calls.where((a) => a.contains('force-stop')).length;
  Future<Map<String, Object?>> recover() => recoverAndroidActor(directory, adb: adb, claims: claims);
}

void main() {
  test('running native app prevents capture; confirmed stop precedes release and is idempotent', () async {
    final f = Fixture();
    await f.actor.prepare();
    f.running = true;
    await f.actor.confirmStarted();
    expect(f.actor.assertStopped, throwing('transport remains'));
    f.forwards['tcp:39000'] = 'tcp:49000';
    await f.actor.close();
    f.actor.assertStopped();
    expect(f.record('android-app.json')['closure'], 'processes-absent');
    expect(f.stops(), 1);
    expect(f.forwards, {'tcp:39000': 'tcp:49000'});
    expect(Directory(f.claims).listSync(), isEmpty);
    await f.actor.close();
    expect(f.stops(), 1);
  });

  test('pre-existing app and multi-user device are refused without stopping applications', () async {
    final f = Fixture()..running = true;
    await expectLater(f.actor.prepare(), throwing('already running'));
    await f.actor.close();
    expect(f.stops(), 0);
    final g = Fixture()..multi = true;
    await expectLater(g.actor.prepare(), throwing('single-user'));
    await g.actor.close();
    expect(g.stops(), 0);
  });

  test('offline and unconfirmed process exit retain both the actor and its transport', () async {
    final f = Fixture();
    await f.actor.prepare();
    f.running = true;
    await f.actor.confirmStarted();
    f.online = false;
    await expectLater(f.actor.close(), throwing('offline'));
    expect(f.stops(), 0);
    f
      ..online = true
      ..stubborn = true;
    await expectLater(f.actor.close(), throwing('remains active'));
    expect(f.record('android-app.json')['phase'], 'running');
    expect(f.forwards.length, 2);
    f.stubborn = false;
    await f.actor.close();
    f.actor.assertStopped();
  });

  test('recovery refuses a live supervisor, then closes a launch with no start receipt without replay', () async {
    final f = Fixture();
    await f.actor.prepare();
    f.running = true;
    await expectLater(f.recover(), throwing('still alive'));
    expect(f.stops(), 0);
    f.dead();
    await f.recover();
    expect(f.record('android-app.json')['phase'], 'stopped');
    expect(f.stops(), 1);
    await f.recover();
    expect(f.stops(), 1);
  });

  test('rebooted device keeps its new app and mappings', () async {
    final f = Fixture();
    await f.actor.prepare();
    f.running = true;
    await f.actor.confirmStarted();
    f.boot = '20000000-0000-4000-8000-000000000002';
    f.forwards['tcp:38001'] = 'tcp:49000';
    await f.actor.close();
    f.actor.assertStopped();
    expect(f.stops(), 0);
    expect(f.record('android-app.json')['closure'], 'original-boot-ended');
    expect(f.forwards.length, 2);
  });

  test('foreign ownership cannot stop the package', () async {
    final f = Fixture();
    await f.actor.prepare();
    f.running = true;
    await f.actor.confirmStarted();
    final claim = Directory(f.claims).listSync().single.path;
    final saved = jsonDecode(File(claim).readAsStringSync()) as Map;
    savePrivateState(claim, {...saved.cast<String, Object?>(), 'owner': '90000000-0000-4000-8000-000000000009'});
    await expectLater(f.actor.close(), throwing('another run'));
    expect(f.stops(), 0);
    savePrivateState(claim, saved);
    await f.actor.close();
  });

  test('a live contained launcher must be stopped before Android cleanup', () async {
    final f = Fixture();
    await f.actor.prepare();
    final launcher = allocateOwnedProcess(f.directory, worker: cliWorker);
    try {
      await launcher.start(command: const ['sleep', '1000'], cwd: f.directory);
      f.running = true;
      await f.actor.confirmStarted();
      await expectLater(f.actor.close(), throwing('launcher still exists'));
      expect(f.stops(), 0);
    } finally {
      await launcher.stop();
      await f.actor.close();
    }
    f.actor.assertStopped();
  });
}
