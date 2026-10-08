import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// HTTP status merged with the JSON body; a body `status` wins, as in the
/// bridge's own protocol.
typedef Answer = Map<String, Object?>;

Future<Answer> moment(Bridge bridge, String op, [Map<String, Object?>? data]) async {
  final (:code, :value) = await call(bridge.url, bridge.token, '/moments/$op', data);
  return {'status': code, ...value};
}

Future<int> raw(Bridge bridge, String path) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('${bridge.url}$path'));
    request.headers.set('Authorization', 'Bearer ${bridge.token}');
    final response = await request.close().timeout(const Duration(seconds: 1));
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Map<String, Object?> projectionOf(Answer value) => ((value['state']! as Map)['projection']! as Map).cast();

void json(String root, String path, Object? value) => writeJson(p.join(root, path), value);

void main() {
  test('named recipes restore drafts across bridge/runtime restart without capturing secrets', () async {
    final root = temporary('moments-');
    for (final dir in ['live-ui', 'moments', 'lib']) {
      Directory(p.join(root, dir)).createSync();
    }
    json(root, 'live-ui/schema.json', <String, Object?>{});
    json(root, 'live-ui/overrides.json', {'version': 1, 'values': <String, Object?>{}});
    File(p.join(root, 'MOMENTS.md')).writeAsStringSync(
      '# Test\nmoments: 0.1\nlayers: client=flutter-draft\n\n## empty\nrun: flutter-draft moments/recipes.json#empty\nOpen the form.\n\n## filled\nfrom: empty\nrun: flutter-draft moments/recipes.json#filled\nFill the email.\n',
    );
    File(p.join(root, 'lib/app.dart')).writeAsStringSync('version one');
    json(root, 'moments/contract.json', {
      'routes': ['/sign-up'],
      'fields': {
        'email': {'maxLength': 100},
      },
      'focus': ['none', 'email'],
      'watch': ['lib/app.dart'],
    });
    final blank = {
      'route': '/sign-up',
      'fields': {'email': ''},
      'focus': 'email',
      'selection': [0, 0],
    };
    json(root, 'moments/recipes.json', {
      'empty': blank,
      'filled': {
        'fields': {'email': 'pilot@example.test'},
        'selection': [18, 18],
      },
    });
    var bridge = await Bridge.start(directory: p.join(root, 'live-ui'), port: 0);
    try {
      final opened = await moment(bridge, 'open', {'name': 'filled'});
      expect((projectionOf(opened)['fields']! as Map)['email'], 'pilot@example.test');
      final recipeProjection = projectionOf(opened);
      expect((await moment(bridge, 'look'))['status'], 'awaiting-runtime');
      final moments = bridge.moments!;
      expect(moments.hasObservedRuntime(), isFalse);
      expect(moments.hasRuntimeClaim(), isFalse);
      await moment(bridge, 'changes?since=&client=first');
      expect(moments.hasRuntimeClaim(), isTrue);
      expect(moments.hasObservedRuntime(), isFalse, reason: 'Claim alone is not a restored screen');
      final draft = {
        ...recipeProjection,
        'fields': {'email': 'continued@example.test'},
        'selection': [22, 22],
      };
      expect(
        (await moment(bridge, 'capture', {
          'client': 'first',
          'revision': opened['revision'],
          'sequence': 2,
          'projection': draft,
        }))['saved'],
        true,
      );
      expect(
        (await moment(bridge, 'capture', {
          'client': 'first',
          'revision': opened['revision'],
          'sequence': 1,
          'projection': blank,
        }))['status'],
        409,
      );
      final session = File(p.join(root, 'moments/.session.json'));
      final disk = session.readAsStringSync();
      await moment(bridge, 'look');
      await moment(bridge, 'look');
      expect(session.readAsStringSync(), disk, reason: 'look is read-only');
      final timing = {
        'clock': 'dart-monotonic',
        'elapsedMs': 20,
        'marks': {
          'main': {'ms': 0, 'visibility': 'visible'},
        },
        'spans': <Object?>[],
        'secret': 'not-stored',
      };
      await moment(bridge, 'observe', {
        'client': 'first',
        'revision': opened['revision'],
        'projection': draft,
        'timing': timing,
      });
      expect(moments.hasObservedRuntime(), isTrue);
      final measured = await moment(bridge, 'look');
      final observed = (measured['observed']! as Map).cast<String, Object?>();
      expect(observed['projection'], draft);
      expect((observed['timing']! as Map)['elapsedMs'], 20);
      expect((observed['timing']! as Map).containsKey('secret'), isFalse);
      expect(session.readAsStringSync(), disk, reason: 'Timing cannot enter saved draft');
      // The authenticated long-poll carries ephemeral pause/resume control without
      // modifying the active Moment, revision or saved draft.
      final prepared = moments.prepareRestart();
      final control = ((await moment(bridge, 'changes?since=${opened['revision']}&client=first'))['restart']! as Map)
          .cast<String, Object?>();
      expect(control['phase'], 'pause');
      expect(
        (await moment(bridge, 'restart-ack', {'id': control['id'], 'client': 'other', 'phase': 'paused'}))['status'],
        409,
      );
      expect(
        (await moment(bridge, 'restart-ack', {'id': control['id'], 'client': 'first', 'phase': 'paused'}))['status'],
        200,
      );
      (await prepared)();
      final resumed = await moment(bridge, 'changes?since=${opened['revision']}&client=first');
      expect(resumed['revision'], opened['revision']);
      expect((resumed['restart']! as Map)['phase'], 'resume');
      await moment(bridge, 'restart-ack', {'id': control['id'], 'client': 'first', 'phase': 'resumed'});
      expect(session.readAsStringSync(), disk);
      final bad = {
        ...draft,
        'fields': {...(draft['fields']! as Map).cast<String, Object?>(), 'password': 'secret'},
      };
      expect(
        (await moment(bridge, 'capture', {
          'client': 'first',
          'revision': opened['revision'],
          'projection': bad,
        }))['status'],
        400,
      );
      expect(session.readAsStringSync(), disk);
      await bridge.close();
      bridge = await Bridge.start(directory: p.join(root, 'live-ui'), port: 0);
      final restored = await moment(bridge, 'changes?since=&client=restarted');
      expect(
        bridge.moments!.hasObservedRuntime(),
        isFalse,
        reason: 'An old runtime observation must not unlock a new runtime',
      );
      expect(projectionOf(restored), draft);
      expect(
        (await moment(bridge, 'capture', {
          'client': 'first',
          'revision': restored['revision'],
          'projection': blank,
        }))['status'],
        409,
      );
      expect(
        (await moment(bridge, 'capture', {
          'client': 'restarted',
          'revision': opened['revision'],
          'projection': blank,
        }))['status'],
        409,
      );
      final waiting = moment(bridge, 'changes?since=${restored['revision']}&client=restarted');
      await Future<void>.delayed(const Duration(milliseconds: 15));
      final presentation = await call(bridge.url, bridge.token, '/state');
      final orphanedPresentation = raw(bridge, '/changes?since=${presentation.value['revision']}&session=retired');
      final orphanedInspector = raw(bridge, '/render/next?client=restarted');
      // Let both real HTTP long-polls reach the bridge before transferring ownership.
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await moment(bridge, 'changes?since=&client=new-owner');
      expect(await orphanedPresentation, 204, reason: 'Do not retain an old presentation poll for 20 seconds');
      expect(await orphanedInspector, 409, reason: 'Old inspector must stop polling');
      expect((await waiting)['status'], 409);
      final reset = await moment(bridge, 'reset', {});
      expect(projectionOf(reset), recipeProjection);
      File(p.join(root, 'lib/app.dart')).writeAsStringSync('version two');
      expect((await moment(bridge, 'look'))['codeChanged'], true);
      expect((await moment(bridge, 'open', {'name': 'missing'}))['status'], 400);
    } finally {
      await bridge.close();
    }
  });

  test('warm screen navigation preserves filters and scroll across process restart', () async {
    final root = temporary('screen-moment-');
    for (final dir in ['live-ui', 'screen', 'lib']) {
      Directory(p.join(root, dir)).createSync();
    }
    json(root, 'live-ui/schema.json', <String, Object?>{});
    json(root, 'live-ui/overrides.json', {'version': 1, 'values': <String, Object?>{}});
    File(p.join(root, 'screen/MOMENTS.md')).writeAsStringSync(
      '# Test\nmoments: 0.1\nlayers: app=flutter-screen\n\n## checkout-open\nrun: flutter-screen recipes.json#checkout-open\nOpen the reservations.\n',
    );
    File(p.join(root, 'lib/app.dart')).writeAsStringSync('one');
    json(root, 'screen/contract.json', {
      'properties': {
        'route': {
          'enum': ['/reservations'],
        },
        'filter': {
          'enum': ['all', 'confirmed'],
        },
        'scrollOffset': {'type': 'number', 'min': 0, 'max': 10000},
      },
      'watch': ['lib/app.dart'],
    });
    final initial = {'route': '/reservations', 'filter': 'all', 'scrollOffset': 0};
    json(root, 'screen/recipes.json', {'checkout-open': initial});
    final options = MomentsOptions(
      directory: p.join(root, 'screen'),
      mapFile: p.join(root, 'screen/MOMENTS.md'),
      executor: 'flutter-screen',
      recipeRef: 'recipes.json',
      initialName: 'checkout-open',
    );
    final legacy = {
      'name': 'checkout-open',
      'recipeHash': 'old-recipe',
      'codeHash': 'old-source',
      'projection': {...initial, 'scrollOffset': 42},
    };
    json(root, 'screen/.session.json', legacy);
    final session = File(p.join(root, 'screen/.session.json'));
    var bridge = await Bridge.start(directory: p.join(root, 'live-ui'), port: 0, momentsOptions: options);
    expect(
      jsonDecode(session.readAsStringSync()),
      legacy,
      reason: 'Read-only startup preserves the legacy file until the next write',
    );
    try {
      final connected = await moment(bridge, 'changes?since=&client=one');
      expect(projectionOf(connected), legacy['projection']);
      final saved = {...initial, 'filter': 'confirmed', 'scrollOffset': 145};
      final capture = {'client': 'one', 'revision': connected['revision'], 'sequence': 1, 'projection': saved};
      expect((await moment(bridge, 'capture', capture))['saved'], true);
      final upgraded = jsonDecode(session.readAsStringSync()) as Map;
      expect(upgraded['version'], 2);
      expect(((upgraded['states'] as Map)['checkout-open'] as Map)['projection'], saved);
      final moved = await moment(bridge, 'open', {'name': 'checkout-open'});
      expect(projectionOf(moved), saved);
      expect(moved['revision'], isNot(connected['revision']));
      expect((await moment(bridge, 'capture', {...capture, 'sequence': 2}))['status'], 409);
      expect(
        (await moment(bridge, 'capture', {
          ...capture,
          'revision': moved['revision'],
          'projection': {...saved, 'scrollOffset': -1},
        }))['status'],
        400,
      );
      expect(
        (await moment(bridge, 'capture', {
          ...capture,
          'revision': moved['revision'],
          'projection': {...saved, 'token': 'forbidden'},
        }))['status'],
        400,
      );
      final report = await moment(bridge, 'observe', {
        'client': 'one',
        'revision': moved['revision'],
        'projection': saved,
      });
      expect(report['observed'], true);
      expect(((await moment(bridge, 'look'))['observed']! as Map)['openToObservedMs'] as num, greaterThanOrEqualTo(0));
      final moments = bridge.moments!;
      final checkpoint = moments.checkpoint();
      expect(
        moments.restorationAfter(checkpoint),
        isNull,
        reason: 'Old runtime acknowledgment cannot confirm refreshed code',
      );
      await moment(bridge, 'changes?since=&client=fresh');
      expect(moments.restorationAfter(checkpoint), isNull, reason: 'Connecting alone is not restoration');
      await moment(bridge, 'observe', {'client': 'fresh', 'revision': moved['revision'], 'projection': saved});
      expect(moments.restorationAfter(checkpoint)!['name'], 'checkout-open');
      File(p.join(root, 'lib/app.dart')).writeAsStringSync('edited-during-build');
      expect(() => moments.markCodeApplied(checkpoint), throwsA(predicate((e) => '$e'.contains('source changed'))));
      expect(
        (await moment(bridge, 'look'))['codeChanged'],
        true,
        reason: 'An edit during compilation cannot be marked applied',
      );
      await bridge.close();
      bridge = await Bridge.start(directory: p.join(root, 'live-ui'), port: 0, momentsOptions: options);
      expect(projectionOf(await moment(bridge, 'changes?since=&client=two')), saved);
      expect(projectionOf(await moment(bridge, 'reset', {})), initial);
    } finally {
      await bridge.close();
    }
  });

  test('Ash manifest drives the bridge catalog, restores named views, and validates captures', () async {
    final root = temporary('ash-moments-');
    Directory(p.join(root, 'live-ui')).createSync();
    Directory(p.join(root, 'moments')).createSync();
    json(root, 'live-ui/schema.json', <String, Object?>{});
    json(root, 'live-ui/overrides.json', {'version': 1, 'values': <String, Object?>{}});
    // Generated from the retained Ash declarations; independent of the active pilot catalog.
    final manifest = (readJson(p.join(package, 'test/fixtures/legacy-moments.json'))! as Map).cast<String, Object?>();
    for (final path in (manifest['watch']! as List).cast<String>()) {
      File(p.join(root, path))
        ..createSync(recursive: true)
        ..writeAsStringSync('source');
    }
    json(root, 'moments/manifest.json', manifest);
    MomentsOptions options({String? openName, bool fresh = false}) => MomentsOptions(
      directory: p.join(root, 'moments'),
      manifestFile: p.join(root, 'moments/manifest.json'),
      initialName: 'checkout-open',
      openName: openName,
      fresh: fresh,
      prepare: (_) async {},
    );
    var bridge = await Bridge.start(directory: p.join(root, 'live-ui'), port: 0, momentsOptions: options());
    Future<({int code, Object? data})> request(String op, [Map<String, Object?>? body]) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(body == null ? 'GET' : 'POST', Uri.parse('${bridge.url}/moments/$op'));
        request.headers
          ..set('Authorization', 'Bearer ${bridge.token}')
          ..set('Content-Type', 'application/json');
        if (body != null) request.add(utf8.encode(jsonEncode(body)));
        final response = await request.close();
        return (code: response.statusCode, data: jsonDecode(await utf8.decoder.bind(response).join()));
      } finally {
        client.close(force: true);
      }
    }

    Map<String, Object?> data(({int code, Object? data}) answer) => (answer.data! as Map).cast();
    Map<String, Object?> projection(({int code, Object? data}) answer) =>
        ((data(answer)['state']! as Map)['projection']! as Map).cast();
    List<Map> catalog(({int code, Object? data}) answer) => (answer.data! as List).cast<Map>();
    try {
      final moments = (manifest['moments']! as Map).keys.cast<String>().toList()..sort();
      expect(catalog(await request('ls')).map((s) => s['name'] as String).toList()..sort(), moments);
      final notifications = await request('open', {'name': 'booking-notifications'});
      expect(projection(notifications)['route'], '/notifications?debugSession=0');
      expect(projection(notifications)['filter'], 'reservation');
      await request('changes?since=&client=notifications');
      final notificationCapture = {
        'client': 'notifications',
        'revision': data(notifications)['revision'],
        'sequence': 1,
        'projection': {...projection(notifications), 'filter': 'payment', 'scrollOffset': 35},
      };
      expect((await request('capture', notificationCapture)).code, 200);
      expect(
        (await request('capture', {
          ...notificationCapture,
          'sequence': 2,
          'projection': {...(notificationCapture['projection']! as Map).cast<String, Object?>(), 'filter': 'invalid'},
        })).code,
        400,
      );
      expect(projection(await request('open', {'name': 'booking-notifications'})), notificationCapture['projection']);
      final review = await request('open', {'name': 'review-draft'});
      await request('changes?since=&client=review');
      final draft = {
        ...projection(review),
        'comment': 'Note 🏕️',
        'scores': {'service-id': 5},
      };
      final captureReview = {
        'client': 'review',
        'revision': data(review)['revision'],
        'sequence': 1,
        'projection': draft,
      };
      expect((await request('capture', captureReview)).code, 200);
      for (final invalid in <Map<String, Object?>>[
        {'comment': 'x' * 2001},
        {'comment': 42},
        {
          'scores': {'service': 6},
        },
        {
          'scores': {'service': 1.5},
        },
        {'scores': <Object?>[]},
        {'filter': 'all'},
        {'route': '/unknown'},
      ]) {
        expect(
          (await request('capture', {
            ...captureReview,
            'sequence': 2,
            'projection': {...draft, ...invalid},
          })).code,
          400,
          reason: '$invalid',
        );
      }
      await request('open', {'name': 'checkout-open'});
      final first = await request('changes?since=&client=first');
      final savedAll = {...projection(first), 'scrollOffset': 24, 'dayFilter': 'saturday'};
      expect(
        data(
          await request('capture', {
            'client': 'first',
            'revision': data(first)['revision'],
            'sequence': 1,
            'projection': savedAll,
          }),
        )['saved'],
        true,
      );
      final opened = await request('open', {'name': 'checkout-confirmed'});
      expect(projection(opened)['filter'], 'confirmed');
      final saved = {...projection(opened), 'scrollOffset': 67.5};
      final capture = {'client': 'first', 'revision': data(opened)['revision'], 'sequence': 1, 'projection': saved};
      expect(data(await request('capture', capture))['saved'], true);
      expect(
        (await request('capture', {
          ...capture,
          'sequence': 2,
          'projection': {...saved, 'filter': 'invalid'},
        })).code,
        400,
      );
      expect(
        (await request('capture', {
          ...capture,
          'sequence': 2,
          'projection': {...saved, 'password': 'forbidden'},
        })).code,
        400,
      );
      expect(projection(await request('open', {'name': 'checkout-confirmed'})), saved);
      final returnAll = await request('open', {'name': 'checkout-open'});
      expect(projection(returnAll), savedAll, reason: 'Switching back resumes the other view');
      expect(
        (await request('capture', {...capture, 'sequence': 3})).code,
        409,
        reason: 'Late captures from the previous moment cannot overwrite the new active view',
      );
      expect(catalog(await request('ls')).firstWhere((s) => s['name'] == 'checkout-open')['active'], true);
      expect(
        catalog(
          await request('ls'),
        ).where((s) => (s['name'] as String).startsWith('checkout')).every((s) => s['saved'] == true),
        isTrue,
      );
      expect(projection(await request('open', {'name': 'checkout-confirmed'})), saved);
      await bridge.close();
      bridge = await Bridge.start(directory: p.join(root, 'live-ui'), port: 0, momentsOptions: options());
      expect(projection(await request('changes?since=&client=second')), saved);
      expect((await request('open', {'name': 'missing'})).code, 400);
      (((manifest['moments']! as Map)['checkout-confirmed'] as Map)['projection'] as Map)['dayFilter'] = 'today';
      json(root, 'moments/manifest.json', manifest);
      expect(data(await request('look'))['recipeChanged'], true);
      expect(projection(await request('reset', {}))['dayFilter'], 'today');
      expect(
        projection(await request('open', {'name': 'checkout-open'})),
        savedAll,
        reason: 'Reset of one moment leaves the other intact',
      );
      expect((await request('open', {'name': 'checkout-open', 'fresh': 'true'})).code, 400);
      final fresh = projection(await request('open', {'name': 'checkout-open', 'fresh': true}));
      expect(fresh['scrollOffset'], 0);
      expect(fresh['dayFilter'], 'all');
      expect(projection(await request('open', {'name': 'checkout-confirmed'}))['dayFilter'], 'today');
      await request('open', {'name': 'checkout-open'});
      await bridge.close();
      bridge = await Bridge.start(
        directory: p.join(root, 'live-ui'),
        port: 0,
        momentsOptions: options(openName: 'checkout-confirmed'),
      );
      expect(
        projection(await request('look'))['filter'],
        'confirmed',
        reason: 'cold open selects requested scene over previously saved scene',
      );
      await bridge.close();
      // A contract can retire a value used by a saved scene. An explicit cold
      // fresh open must recover it instead of failing before evaluating the recipe.
      final disk = (readJson(p.join(root, 'moments/.session.json'))! as Map).cast<String, Object?>();
      (((disk['states']! as Map)['checkout-confirmed'] as Map)['projection'] as Map)['filter'] = 'retired';
      json(root, 'moments/.session.json', disk);
      bridge = await Bridge.start(
        directory: p.join(root, 'live-ui'),
        port: 0,
        momentsOptions: options(openName: 'checkout-confirmed', fresh: true),
      );
      expect(projection(await request('look'))['filter'], 'confirmed');
    } finally {
      await bridge.close();
    }
  });

  test('prepared open awaits launch restoration; check-only opens never reapply sessions', () async {
    final root = temporary('prepared-session-');
    for (final dir in ['live-ui', 'moments']) {
      Directory(p.join(root, dir)).createSync();
    }
    json(root, 'live-ui/schema.json', <String, Object?>{});
    json(root, 'live-ui/overrides.json', {'version': 1, 'values': <String, Object?>{}});
    json(root, 'moments/manifest.json', {
      'version': 1,
      'watch': <Object?>[],
      'properties': {
        'route': {
          'enum': ['/sign-in'],
        },
        'phase': {
          'enum': ['anonymous'],
        },
      },
      'moments': {
        'login': {
          'description': 'Session',
          'projection': {'route': '/sign-in', 'phase': 'anonymous'},
          'checks': <Object?>[],
          'backend': {'recipe': 'login'},
        },
      },
    });
    final events = <String>[];
    var fail = false;
    late Bridge bridge;
    bridge = await Bridge.start(
      directory: p.join(root, 'live-ui'),
      port: 0,
      momentsOptions: MomentsOptions(
        manifestFile: p.join(root, 'moments/manifest.json'),
        prepare: (_) async => events.add('prepare'),
        afterPreparedOpen: (_) async {
          expect((bridge.moments!.inspect()['state']! as Map)['name'], 'login');
          events.add('restore');
          if (fail) throw Exception('Session restoration failed');
        },
      ),
    );
    addTearDown(bridge.close);
    Future<int> open(bool prepare) async =>
        (await call(bridge.url, bridge.token, '/moments/open', {'name': 'login', 'prepare': prepare})).code;
    expect(await open(true), 200);
    expect(events, ['prepare', 'restore']);
    expect(await open(false), 200);
    expect(events, ['prepare', 'restore']);
    fail = true;
    expect(await open(true), 400);
  });
}
