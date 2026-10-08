import 'dart:convert';
import 'dart:io';

import 'package:moments/src/android_transport.dart';
import 'package:moments/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// A fake `adb` for one emulator: reverse mappings in memory, a boot id and
/// switches for going offline or losing a creation receipt.
final class Fixture {
  Fixture() : root = temporary('mana-android-') {
    claims = p.join(root, 'claims');
    directory = p.join(root, 'one');
    Directory(directory).createSync();
    Process.runSync('chmod', ['700', directory]);
  }

  final String root;
  late final String claims, directory;
  var boot = '10000000-0000-4000-8000-000000000001', offline = false;
  void Function()? afterCreate;
  final forwards = <String, String>{};
  final calls = <List<String>>[];

  String adb(List<String> args) {
    calls.add(args);
    expect(args[0], '-s');
    expect(args[1], 'emulator-5554');
    if (offline) throw const MomentsError('offline');
    if (args[2] == 'shell') return args.contains('getprop') ? '36' : boot;
    if (args[3] == '--list')
      return [for (final MapEntry(:key, :value) in forwards.entries) 'host $key $value'].join('\n');
    if (args[3] == '--no-rebind') {
      expect(forwards.containsKey(args[4]), isFalse);
      final journal = jsonDecode(File(p.join(directory, 'transport.json')).readAsStringSync()) as Map;
      expect(
        (journal['ports'] as List).cast<Map>().any((x) => 'tcp:${x['port']}' == args[4] && x['phase'] == 'creating'),
        isTrue,
        reason: 'Intent must precede allocation',
      );
      forwards[args[4]] = args[5];
      afterCreate?.call();
      return '';
    }
    if (args[3] == '--remove') {
      forwards.remove(args[4]);
      return '';
    }
    fail('Unexpected adb command $args');
  }

  AndroidTransport transport({String? directory, List<int> ports = const [38001, 38002]}) => AndroidTransport(
    directory: directory ?? this.directory,
    device: 'emulator-5554',
    ports: ports,
    adb: adb,
    claims: claims,
  );

  /// Makes the journal's supervisor a process that no longer exists.
  void dead() {
    final file = File(p.join(directory, 'transport.json'));
    final journal = (jsonDecode(file.readAsStringSync()) as Map).cast<String, Object?>();
    (journal['supervisor']! as Map)['boot'] = '90000000-0000-4000-8000-000000000009';
    file.writeAsStringSync(jsonEncode(journal));
  }

  int claimCount() => Directory(claims).listSync().length;
}

void main() {
  test('explicit serial only; occupied endpoints survive preflight', () async {
    final f = Fixture();
    expect(
      () => AndroidTransport(directory: f.directory, device: '-d', ports: const [38001], adb: f.adb, claims: f.claims),
      throwsA(anything),
    );
    f.forwards['tcp:38001'] = 'tcp:45000';
    await expectLater(f.transport().start(), throwing('occupied'));
    expect(f.forwards['tcp:38001'], 'tcp:45000');
    expect(File(p.join(f.directory, 'transport.json')).existsSync(), isFalse);
  });

  test('durable claim excludes another workspace and cleanup preserves unrelated reverse', () async {
    final f = Fixture(), a = f.transport();
    await a.start();
    f.forwards['tcp:39000'] = 'tcp:49000';
    final b = f.transport(directory: p.join(f.root, 'two'), ports: const [38003]);
    await expectLater(b.start(), throwing('claimed by another run'));
    await b.close();
    expect(f.forwards.length, 3);
    await a.close();
    expect(f.forwards, {'tcp:39000': 'tcp:49000'});
    await a.close();
    expect(f.claimCount(), 0);
  });

  test('lost creation receipt is recovered from durable intent, never recreated', () async {
    final f = Fixture();
    f.afterCreate = () => throw const MomentsError('receipt lost');
    await expectLater(f.transport().start(), throwing('receipt lost'));
    expect(f.forwards.length, 1);
    final count = f.calls.where((x) => x[3] == '--no-rebind').length;
    f.dead();
    await recoverAndroidTransport(f.directory, adb: f.adb, claims: f.claims);
    expect(f.forwards, isEmpty);
    expect(f.calls.where((x) => x[3] == '--no-rebind').length, count);
  });

  test('offline device retains claim; conflicting replacement is not deleted', () async {
    final f = Fixture(), a = f.transport();
    await a.start();
    f.offline = true;
    await expectLater(a.close(), throwing('offline'));
    expect(f.claimCount(), 1);
    f.offline = false;
    f.forwards['tcp:38002'] = 'tcp:49000';
    await expectLater(a.close(), throwing('replaced'));
    expect(f.forwards.length, 2);
    f.forwards['tcp:38002'] = 'tcp:38002';
    await a.close();
    expect(f.forwards, isEmpty);
  });

  test('device reboot releases old claim without deleting new boot mappings', () async {
    final f = Fixture(), a = f.transport();
    await a.start();
    f.boot = '20000000-0000-4000-8000-000000000002';
    f.forwards['tcp:38002'] = 'tcp:49000';
    final state = await a.close();
    expect(state['rebooted'], true);
    expect(f.forwards.length, 2);
    expect(f.calls.where((x) => x[3] == '--remove').length, 0);
  });

  test('recovery rejects mismatched run identity before touching endpoints', () async {
    final f = Fixture();
    await f.transport().start();
    final count = f.calls.length;
    await expectLater(f.transport().close(), throwing('identity'));
    expect(f.calls.length, count);
    f.dead();
    await recoverAndroidTransport(f.directory, adb: f.adb, claims: f.claims);
  });

  test('recovery cannot tear down a live supervisor', () async {
    final f = Fixture(), a = f.transport();
    await a.start();
    expect(() => recoverAndroidTransport(f.directory, adb: f.adb, claims: f.claims), throwing('still alive'));
    expect(f.forwards.length, 2);
    await a.close();
  });
}
