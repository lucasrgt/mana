import 'dart:async';
import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/inspect.dart';
import 'package:moments/src/journey_lease.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

final class Dev implements Development {
  Dev(this.onRefresh);
  final void Function() onRefresh;
  @override
  Map<String, Object?> status() => {'phase': 'ready'};
  @override
  Future<Map<String, Object?>> Function()? get inspect => null;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => (_) {
    onRefresh();
    return {};
  };
  @override
  Future<void> Function()? get stop => null;
  @override
  Renewal? get renewal => null;
}

void main() {
  test('only the owner can operate until a successful finish releases the instance', () {
    final lease = JourneyLease();
    final first = lease.acquire('inbox');
    expect(() => lease.acquire('other'), throwing('Another journey'));
    expect(() => lease.assertAccess(null), throwing('ownership mismatch'));
    expect(() => lease.assertAccess('other'), throwing('ownership mismatch'));
    lease.assertAccess(first['id']);
    expect(lease.finish(first['id'], true)['phase'], 'idle');
    expect(() => lease.assertAccess(first['id']), throwing('no longer exists'));
    expect(lease.acquire('inbox')['id'], isNot(first['id']));
  });

  test('expiry fences the old owner and never automatically releases uncertain writes', () {
    var clock = 0, busy = false;
    final lease = JourneyLease(now: () => clock, ttl: 10, busy: () => busy);
    final first = lease.acquire('inbox');
    clock = 9;
    lease.heartbeat(first['id']);
    clock = 18;
    lease.assertAccess(first['id']);
    clock = 19;
    expect(lease.status()['phase'], 'expired');
    expect(() => lease.heartbeat(first['id']), throwing('expired'));
    expect(() => lease.assertAccess(first['id']), throwing('expired'));
    expect(() => lease.acquire('inbox'), throwing('Another journey'));
    expect(() => lease.recover(first['id'], false), throwing('explicitly recovered'));
    busy = true;
    expect(() => lease.recover(first['id'], true), throwing('still in flight'));
    busy = false;
    expect(lease.recover(first['id'], true)['effects'], 'not-rolled-back');
    final next = lease.acquire('inbox');
    expect(next['id'], isNot(first['id']));
    expect(() => lease.assertAccess(first['id']), throwing('mismatch'));
  });

  test('failed runs require explicit recovery and cannot release active preparation', () {
    var busy = false;
    final lease = JourneyLease(busy: () => busy);
    final first = lease.acquire('inbox');
    expect(() => lease.recover(first['id'], true), throwing('interrupted'));
    busy = true;
    expect(() => lease.finish(first['id'], false), throwing('in-flight'));
    busy = false;
    expect(lease.finish(first['id'], false)['phase'], 'attention');
    expect(() => lease.assertAccess(first['id']), throwing('inspection'));
    lease.recover(first['id'], true);
    expect(lease.status()['phase'], 'idle');
  });

  test('real bridge rejects competing preparations and refreshes before calling app adapters', () async {
    final project = temporary('journey-lease-');
    for (final dir in ['moments', 'lib']) {
      Directory(p.join(project, dir)).createSync();
    }
    File(p.join(project, 'lib/view.dart')).writeAsStringSync('// view');
    writeJson(p.join(project, 'moments/manifest.json'), {
      'version': 1,
      'properties': {
        'route': {
          'enum': ['/inbox'],
        },
      },
      'watch': ['lib/view.dart'],
      'moments': {
        'inbox': {
          'projection': {'route': '/inbox'},
          'backend': {'recipe': 'inbox'},
          'checks': <Object?>[],
        },
      },
    });
    var prepares = 0, refreshes = 0;
    Completer<void>? completePreparation;
    final bridge = await Bridge.start(
      project: project,
      port: 0,
      momentsOptions: MomentsOptions(
        manifestFile: p.join(project, 'moments/manifest.json'),
        initialName: 'inbox',
        prepare: (_) async {
          prepares++;
          completePreparation = Completer<void>();
          await completePreparation!.future;
        },
      ),
      development: Dev(() => refreshes++),
    );
    addTearDown(bridge.close);
    Future<({int code, Map<String, Object?> value})> request(String path, [Map<String, Object?>? data]) =>
        call(bridge.url, bridge.token, path, data);
    final first = (await request('/journey/lease', {'operation': 'acquire', 'name': 'inbox'})).value;
    expect((await request('/journey/lease', {'operation': 'acquire', 'name': 'inbox'})).code, 400);
    for (final path in ['/moments/open', '/moments/reset', '/dev/refresh', '/dev/renew']) {
      expect((await request(path, {'name': 'inbox'})).code, 400, reason: path);
    }
    expect(prepares, 0);
    expect(refreshes, 0);
    final opening = request('/moments/open', {'name': 'inbox', 'journeyId': first['id']});
    // Wait on the actual adapter hook, not a guessed preparation duration.
    for (var i = 0; completePreparation == null && i < 500; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(prepares, 1);
    expect(
      (await request('/journey/lease', {'operation': 'finish', 'journeyId': first['id'], 'passed': true})).code,
      400,
    );
    expect(((await request('/dev/status')).value['journey']! as Map)['id'], first['id']);
    completePreparation!.complete();
    expect((await opening).code, 200);
    expect(
      (await request('/journey/lease', {
        'operation': 'finish',
        'journeyId': first['id'],
        'passed': true,
      })).value['phase'],
      'idle',
    );
    expect((await request('/dev/refresh', {})).code, 202);
    expect(refreshes, 1);
    expect((await request('/moments/open', {'name': 'inbox', 'journeyId': first['id']})).code, 400);
  });

  test('durable ownership fences supervisor replacement and recovery survives another restart', () {
    final file = p.join(temporary('journey-durable-'), '.journey.json');
    final original = JourneyLease(file: file);
    final owner = original.acquire('inbox');
    final operation = {'operation': 'fill', 'id': owner['id'], 'target': 'secret-field'};
    original.note(owner['id'], operation);
    final replacement = JourneyLease(file: file);
    expect(replacement.status(), {
      ...owner,
      'phase': 'attention',
      'reason': 'supervisor-restarted',
      'lastOperation': operation,
    });
    expect(() => replacement.acquire('inbox'), throwing('Another journey'));
    expect(() => replacement.assertAccess(owner['id']), throwing('inspection'));
    expect(() => replacement.heartbeat(owner['id']), throwing('expired'));
    expect(replacement.finish(owner['id'], true)['phase'], 'attention');
    expect(replacement.recover(owner['id'], true)['effects'], 'not-rolled-back');
    expect(JourneyLease(file: file).status()['phase'], 'idle');
  });

  test('failed journal writes never grant ownership or release an uncertain operation', () {
    final file = p.join(temporary('journey-io-'), '.journey.json'), lease = JourneyLease(file: file);
    Directory('$file.tmp').createSync();
    expect(() => lease.acquire('inbox'), throwsA(anything));
    expect(lease.status()['phase'], 'idle');
    Directory('$file.tmp').deleteSync(recursive: true);
    final owner = lease.acquire('inbox');
    lease.finish(owner['id'], false);
    Directory('$file.tmp').createSync();
    expect(() => lease.recover(owner['id'], true), throwsA(anything));
    expect(lease.status()['phase'], 'attention');
    Directory('$file.tmp').deleteSync(recursive: true);
    expect(JourneyLease(file: file).status()['id'], owner['id']);
  });

  test('corrupt journals and payloads cannot silently become idle ownership', () {
    final file = p.join(temporary('journey-corrupt-'), '.journey.json');
    for (final content in [
      '{',
      'null',
      '{}',
      '{"version":2,"lease":null}',
      '{"version":1,"lease":null,"unknown":true}',
    ]) {
      File(file).writeAsStringSync(content);
      expect(() => JourneyLease(file: file), throwsA(anything), reason: content);
    }
    File(file).deleteSync();
    final lease = JourneyLease(file: file), owner = lease.acquire('inbox');
    for (final operation in <Map<String, Object?>>[
      {'operation': 'prepare', 'text': 'private'},
      {'operation': 'prepare', 'target': 'hidden'},
      {'operation': 'fill', 'id': owner['id'], 'target': 'field', 'text': 'private'},
      {
        'operation': 'tap',
        'id': [owner['id']],
        'target': 'field',
      },
      {'operation': 'tap', 'id': owner['id'], 'target': 123},
    ]) {
      expect(() => lease.note(owner['id'], operation), throwing('Invalid'), reason: '$operation');
    }
  });

  test('bridge restart retains journey and duplicate startup cannot change live ownership', () async {
    final project = temporary('journey-bridge-durable-');
    Directory(p.join(project, 'moments')).createSync();
    writeJson(p.join(project, 'moments/manifest.json'), {
      'version': 1,
      'properties': {
        'route': {
          'enum': ['/inbox'],
        },
      },
      'watch': <Object?>[],
      'moments': {
        'inbox': {
          'projection': {'route': '/inbox'},
          'checks': <Object?>[],
        },
      },
    });
    Future<Bridge> start() => Bridge.start(
      project: project,
      port: 0,
      momentsOptions: MomentsOptions(manifestFile: p.join(project, 'moments/manifest.json'), initialName: 'inbox'),
    );
    var bridge = await start();
    addTearDown(() => bridge.close());
    Future<({int code, Map<String, Object?> value})> request(String path, Map<String, Object?> data) =>
        call(bridge.url, bridge.token, path, data);
    final owner = (await request('/journey/lease', {'operation': 'acquire', 'name': 'inbox'})).value;
    await expectLater(start(), throwing('already exists'));
    expect(bridge.journeyStatus()['phase'], 'active');
    await bridge.close();
    bridge = await start();
    expect(bridge.journeyStatus()['phase'], 'attention');
    expect(bridge.journeyStatus()['id'], owner['id']);
    expect((await request('/moments/open', {'name': 'inbox', 'journeyId': owner['id']})).code, 400);
    expect(
      (await request('/journey/lease', {
        'operation': 'recover',
        'journeyId': owner['id'],
        'acknowledge': true,
      })).value['phase'],
      'idle',
    );
  });
}
