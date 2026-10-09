import 'dart:convert';
import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/check.dart';
import 'package:moments/src/inspect_compact.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

const route = '/inbox';
const properties = {
  'route': {
    'enum': [route],
  },
  'filter': {
    'enum': ['all', 'reservation'],
  },
  'ids': {'type': 'string', 'maxLength': 100, 'restore': false},
  'read': {
    'enum': ['yes', 'no'],
    'restore': false,
  },
};
const projection = {'route': route, 'filter': 'reservation'};
const checks = [
  {'name': 'filter', 'kind': 'restored'},
  {'name': 'read', 'kind': 'ui_equals', 'field': 'read', 'equals': 'yes'},
  {'name': 'persisted', 'kind': 'backend_equals', 'field': 'read', 'equals': true, 'match': 'ids'},
];

typedef Answer = ({int status, Map<String, Object?> data});

/// A bridge over one `inbox` Moment.
final class Fixture {
  Fixture(String prefix, {bool withChecks = true}) : root = temporary(prefix) {
    for (final dir in ['moments', 'lib']) {
      Directory(p.join(root, dir)).createSync();
    }
    File(p.join(root, 'lib/view.dart')).writeAsStringSync('// view');
    writeJson(manifestFile, {
      'version': 1,
      'properties': properties,
      'watch': ['lib/view.dart'],
      'moments': {
        'inbox': {'projection': projection, if (withChecks) 'checks': checks},
      },
    });
  }

  final String root;
  late Bridge bridge;
  String get manifestFile => p.join(root, 'moments/manifest.json');
  String get sessionFile => p.join(root, 'moments/.session.json');

  Future<Bridge> start({String? initialName}) async {
    bridge = await Bridge.start(
      project: root,
      port: 0,
      momentsOptions: MomentsOptions(manifestFile: manifestFile, initialName: initialName),
    );
    addTearDown(bridge.close);
    return bridge;
  }

  Future<Answer> moments(String path, [Map<String, Object?>? data]) async {
    final (:code, :value) = await call(bridge.url, bridge.token, '/moments/$path', data);
    return (status: code, data: value);
  }

  Future<Answer> raw(String path, [Map<String, Object?>? data]) async {
    final (:code, :value) = await call(bridge.url, bridge.token, path, data);
    return (status: code, data: value);
  }
}

Map<String, Object?> state(Answer answer) => ((answer.data['state']! as Map)['projection']! as Map).cast();

void main() {
  test('observations cannot be persisted or replayed, including saved state from an older contract', () async {
    final f = Fixture('moment-observations-');
    writeJson(f.sessionFile, {
      'version': 2,
      'active': 'inbox',
      'states': {
        'inbox': {
          'name': 'inbox',
          'projection': {...projection, 'ids': 'old-id', 'read': 'yes'},
        },
      },
    });
    final before = File(f.sessionFile).readAsStringSync();
    await f.start();
    final connected = await f.moments('changes?client=first');
    expect(state(connected), projection);
    expect(
      File(f.sessionFile).readAsStringSync(),
      before,
      reason: 'Read-only startup does not rewrite the old session',
    );
    final captured = {...projection, 'filter': 'all', 'ids': 'fresh-id', 'read': 'no'};
    final message = {'client': 'first', 'revision': connected.data['revision'], 'sequence': 1, 'projection': captured};
    expect((await f.moments('capture', message)).status, 200);
    final disk = readJson(f.sessionFile)! as Map;
    expect(((disk['states'] as Map)['inbox'] as Map)['projection'], {...projection, 'filter': 'all'});
    expect(((await f.moments('look')).data['observed']! as Map)['projection'], captured);
    expect(
      (await f.moments('observe', {
        ...message,
        'projection': {...projection},
      })).status,
      400,
      reason: 'Missing observations are not silently defaulted',
    );
    expect(
      (await f.moments('observe', {
        ...message,
        'projection': {...captured, 'read': 'invented'},
      })).status,
      400,
    );
    expect(
      (await f.moments('observe', {
        ...message,
        'projection': {...captured, 'secret': 'never'},
      })).status,
      400,
    );
    expect(File(f.sessionFile).readAsStringSync().contains('fresh-id'), isFalse);
    await f.bridge.close();
    await f.start();
    final restarted = await f.moments('changes?client=second');
    expect(state(restarted), {...projection, 'filter': 'all'});
    expect((await f.moments('look')).data['observed'], isNull, reason: 'Restart must observe the app again');
    final opened = await f.moments('open', {'name': 'inbox', 'fresh': true, 'prepare': false});
    expect(state(opened), projection);
  });

  test('fresh observations compare with the actual backend while only presentation must restore', () {
    final observed = {...projection, 'ids': 'actual-id', 'read': 'yes'};
    final backend = {
      'status': 'ready',
      'projection': {'ids': 'actual-id', 'read': true},
    };
    final result = evaluateChecks(
      checks,
      expected: projection,
      observed: observed,
      backend: backend,
      properties: properties,
    );
    expect(result.map((c) => c['status']), ['passed', 'passed', 'passed']);
    expect(result[2]['identitySource'], 'observed-ui');
    final wrong = evaluateChecks(
      checks,
      expected: projection,
      observed: observed,
      backend: {
        ...backend,
        'projection': {'ids': 'other', 'read': true},
      },
      properties: properties,
    );
    expect(wrong[2]['status'], 'unavailable');
    final lost = evaluateChecks(
      checks,
      expected: projection,
      observed: {...observed, 'filter': 'all', 'read': 'no'},
      backend: backend,
      properties: properties,
    );
    expect(lost[0]['status'], 'failed');
    expect(lost[1]['status'], 'failed');
    expect(
      evaluateChecks(
        checks,
        expected: projection,
        observed: projection,
        backend: backend,
        properties: properties,
      )[1]['status'],
      'unavailable',
    );
  });

  test('compact inspection keeps live observations separate from restored presentation', () {
    final observed = {...projection, 'ids': 'actual-id', 'read': 'yes'};
    final full = {
      'moment': {'name': 'inbox', 'savedProjection': projection},
      'screen': {
        'lastReported': {'projection': observed, 'matchesRevision': true},
      },
      'sources': <String, Object?>{},
    };
    final manifest = {
      'version': 1,
      'properties': properties,
      'watch': ['view.dart'],
      'moments': {
        'inbox': {'projection': projection, 'checks': checks},
      },
    };
    final reported = ((compactInspection(full, manifest)['screen']! as Map)['lastReported']! as Map)
        .cast<String, Object?>();
    expect(reported['matchesSaved'], true);
    expect(reported['observations'], {'ids': 'actual-id', 'read': 'yes'});
    expect(reported.containsKey('projection'), isFalse);
  });

  test('post-compile frame challenges reject old reports, wrong owners, duplicates and undeclared fields', () async {
    final f = Fixture('moment-frame-');
    final bridge = await f.start(initialName: 'inbox');
    final moments = bridge.moments!;
    expect(moments.canReload(), isFalse);
    final revision = (await f.moments('changes?client=first&frame=1')).data['revision'];
    final message = {
      'revision': revision,
      'client': 'first',
      'projection': {...projection, 'ids': 'id', 'read': 'no'},
    };
    await f.moments('observe', message);
    expect(moments.canReload(), isTrue);
    expect((await f.moments('frame-ack', {...message, 'id': 'before-compile'})).status, 409);
    final checkpoint = moments.checkpoint();
    final id = moments.requestFrame(checkpoint);
    expect(moments.frameAfter(id), isNull, reason: 'Existing observations cannot prove a new frame');
    final control = (await f.moments('changes?client=first&since=$revision')).data['frame'];
    expect(control, {'id': id, 'revision': revision});
    for (final invalid in <Map<String, Object?>>[
      {'id': 'old'},
      {'client': 'retired'},
      {'revision': 'old'},
      {
        'projection': {...(message['projection']! as Map).cast<String, Object?>(), 'password': 'undeclared'},
      },
    ]) {
      expect((await f.moments('frame-ack', {...message, 'id': id, ...invalid})).status, isNot(200), reason: '$invalid');
      expect(moments.frameAfter(id), isNull);
    }
    expect((await f.moments('frame-ack', {...message, 'id': id})).status, 200);
    expect((moments.frameAfter(id)!['projection']! as Map)['read'], 'no');
    expect((await f.moments('frame-ack', {...message, 'id': id})).status, 409);
    expect(state(await f.moments('look')), projection, reason: 'Fresh observations never persist domain values');
    moments.cancelFrame(id);
    final second = moments.requestFrame(checkpoint);
    await f.moments('changes?client=replacement&frame=1');
    expect(moments.frameAfter(second), isNull);
    expect((await f.moments('frame-ack', {...message, 'id': second})).status, 409);
    expect(() => moments.requestFrame(checkpoint), throwsA(predicate((e) => '$e'.contains('runtime changed'))));
  });

  test('owned capture requires a fresh sequenced frame and persists only restorable fields', () async {
    final f = Fixture('moment-capture-', withChecks: false);
    File(p.join(f.root, 'lib/view.dart')).writeAsStringSync('// original');
    await f.start(initialName: 'inbox');
    final revision = (await f.raw('/moments/changes?client=owner&frame=1&captureFrame=1')).data['revision'];
    final value = {
      'revision': revision,
      'client': 'owner',
      'projection': {...projection, 'ids': 'new-id', 'read': 'yes', 'filter': 'all'},
    };
    await f.raw('/moments/observe', value);
    expect((await f.raw('/moments/settle', {'revision': revision, 'client': 'owner'})).status, isNot(200));
    final lease = (await f.raw('/journey/lease', {'operation': 'acquire', 'name': 'inbox'})).data;
    final pending = f.raw('/moments/settle', {'revision': revision, 'client': 'owner', 'journeyId': lease['id']});
    final control = ((await f.raw('/moments/changes?client=owner&since=$revision')).data['frame']! as Map)
        .cast<String, Object?>();
    expect(control['capture'], true);
    for (final extra in <Map<String, Object?>>[
      {},
      {'capture': true, 'sequence': 0},
      {'capture': true, 'sequence': 1, 'client': 'old'},
    ]) {
      expect(
        (await f.raw('/moments/frame-ack', {...value, 'id': control['id'], ...extra})).status,
        isNot(200),
        reason: '$extra',
      );
    }
    expect(
      (await f.raw('/moments/frame-ack', {...value, 'id': control['id'], 'capture': true, 'sequence': 2})).status,
      200,
    );
    final captured = (await pending).data;
    expect(captured['status'], 'captured');
    expect(captured['sequence'], 2);
    final look = (await f.raw('/moments/look')).data;
    final saved = ((look['state']! as Map)['projection']! as Map).cast<String, Object?>();
    expect(saved['filter'], 'all');
    expect(saved.containsKey('ids'), isFalse);
    expect(((look['observed']! as Map)['projection']! as Map)['ids'], 'new-id');
    expect((look['observed']! as Map)['captureSequence'], 2);
    expect(
      (await f.raw('/moments/capture', {
        ...value,
        'sequence': 1,
        'projection': {...(value['projection']! as Map).cast<String, Object?>(), 'filter': 'reservation'},
      })).status,
      409,
    );
    expect(
      (await f.raw('/journey/lease', {'operation': 'finish', 'journeyId': lease['id'], 'passed': true})).data['phase'],
      'idle',
    );
  });

  test('runtime blockers retain drafts, reject stale clients and cannot certify restoration', () async {
    final f = Fixture('moment-blocker-');
    final bridge = await f.start(initialName: 'inbox');
    final moments = bridge.moments!;
    final first = (await f.moments('changes?client=first&frame=1')).data;
    expect(first['runtimeBlocker'], 1);
    final saved = File(f.sessionFile).readAsStringSync();
    final observed = {
      'client': 'first',
      'revision': first['revision'],
      'projection': {...projection, 'ids': 'live', 'read': 'yes'},
    };
    await f.moments('observe', observed);
    final checkpoint = moments.checkpoint(), frameId = moments.requestFrame(checkpoint);
    final block = {
      'client': 'first',
      'revision': first['revision'],
      'sequence': 1,
      'reason': 'authentication-required',
      'frameId': frameId,
    };
    expect((await f.moments('blocker', {...block, 'message': 'arbitrary text'})).status, 400);
    expect((await f.moments('blocker', {...block, 'reason': 'invented'})).status, 400);
    expect((await f.moments('blocker', block)).status, 200);
    expect((await f.moments('look')).data['status'], 'blocked');
    expect((await f.moments('look')).data['observed'], isNull);
    expect((await f.moments('observe', observed)).status, 409);
    expect((await f.moments('capture', {...observed, 'sequence': 1})).status, 409);
    expect((await f.moments('frame-ack', {...observed, 'id': frameId})).status, 409);
    expect(moments.blockerAfter(checkpoint, frameId: frameId)!['reason'], 'authentication-required');
    expect(moments.blockerAfter(checkpoint, frameId: 'old'), isNull);
    expect(moments.blockerAfter(checkpoint, fullRestart: true), isNull);
    expect(
      (await f.moments('blocker', {...block, 'reason': null})).status,
      409,
      reason: 'Old clear cannot undo a later report',
    );
    expect((await f.moments('blocker', {...block, 'sequence': 2, 'reason': null})).status, 200);
    expect((await f.moments('look')).data['observed'], isNull, reason: 'Clearing is not an observation');
    expect((await f.moments('frame-ack', {...observed, 'id': frameId})).status, 200);
    moments.cancelFrame(frameId);
    final next = (await f.moments('changes?client=second&frame=1')).data;
    expect(
      (await f.moments('blocker', {...block, 'sequence': 3})).status,
      409,
      reason: 'Retired runtime cannot block its replacement',
    );
    expect(
      (await f.moments('blocker', {
        'client': 'second',
        'revision': next['revision'],
        'sequence': 1,
        'reason': 'session-unavailable',
      })).status,
      200,
    );
    expect(moments.blockerAfter(checkpoint, fullRestart: true)!['reason'], 'session-unavailable');
    expect(moments.restorationAfter(checkpoint), isNull);
    final moved = (await f.moments('open', {'name': 'inbox', 'prepare': false})).data;
    expect(moved['revision'], isNot(next['revision']));
    expect((await f.moments('look')).data['blocker'], isNull);
    expect(
      (await f.moments('blocker', {
        'client': 'second',
        'revision': next['revision'],
        'sequence': 2,
        'reason': null,
      })).status,
      409,
    );
    final current = jsonDecode(File(f.sessionFile).readAsStringSync()) as Map;
    expect(
      ((current['states'] as Map)['inbox'] as Map)['projection'],
      (((jsonDecode(saved) as Map)['states'] as Map)['inbox'] as Map)['projection'],
    );
  });
}
