import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moments/src/check.dart';
import 'package:moments/src/journey.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

typedef Call = ({String path, Map<String, Object?>? data});

/// A fake bridge for one `review` Moment. Each option bends one observation.
final class Fixture {
  Fixture({
    this.journey = false,
    this.staleDeclaration = false,
    this.noChecks = false,
    this.divergence = const {},
    this.awaitingRuntime = false,
    this.backendBusy = false,
    this.target,
    this.targetChanges = false,
    this.backendPending = false,
    this.missingIdentity = false,
    this.backendStopped = false,
    this.backendDirty = false,
    this.backendRestart = false,
    this.backendSourceChanges = false,
    this.leaseBusy = false,
    this.expired = false,
    this.unknownGesture = false,
    this.superseded = false,
    this.offline = false,
    this.dirty = false,
    this.declarationChanges = false,
    this.sourceChanges = false,
    this.unavailable = false,
    this.published,
    this.wrongEntity = false,
    this.onRequest,
  }) {
    project = temporary('moment-check-');
    Directory(p.join(project, 'moments')).createSync();
    Directory(p.join(project, 'lib')).createSync();
    File(p.join(project, 'lib/view.dart')).writeAsStringSync('original');
    File(p.join(project, 'moments/declaration.ex')).writeAsStringSync('declaration');
    final source = {'file': 'declaration.ex', 'sha256': sha256.convert(utf8.encode('declaration')).toString()};
    if (staleDeclaration) File(p.join(project, 'moments/declaration.ex')).writeAsStringSync('edited');
    final checks = [
      {'name': 'draft', 'kind': 'restored', 'field': 'modal', 'equals': 'rating'},
      {
        'name': 'unpublished',
        'kind': 'backend_equals',
        'field': 'published',
        'equals': false,
        'match': 'transactionId',
      },
    ];
    writeJson(manifestFile, {
      'watch': ['lib/view.dart'],
      'moments': {
        'review': {
          'source': source,
          'checks': noChecks ? <Object?>[] : checks,
          if (journey)
            'steps': [
              {
                'name': 'press',
                'kind': 'tap',
                'target': 'action',
                'until': ['unpublished'],
              },
            ],
        },
      },
    });
  }

  final bool journey, staleDeclaration, noChecks, awaitingRuntime, backendBusy, targetChanges, backendPending;
  final bool missingIdentity, backendStopped, backendDirty, backendRestart, backendSourceChanges, leaseBusy, expired;
  final bool unknownGesture, superseded, offline, dirty, declarationChanges, sourceChanges, unavailable, wrongEntity;
  final bool? published;
  final Map<String, Object?> divergence;
  final Map<String, Object?>? target;
  final void Function(String path, Map<String, Object?>? data)? onRequest;
  late final String project;
  var _inspected = false;
  final reportedAt = DateTime.now().toUtc().toIso8601String();

  String get manifestFile => p.join(project, 'moments/manifest.json');

  Map<String, Object?> get expected => {
    'route': '/reviews',
    'modal': 'rating',
    'transactionId': 'tx-1',
    'comment': 'PRIVATE DRAFT SENTINEL',
    'scores': {'service': 4},
    'scrollOffset': 35,
  };

  Map<String, Object?> get _state => {'name': 'review', 'projection': expected};

  Map<String, Object?> get _observed => {
    'client': 'client',
    'revision': 'revision',
    'projection': {...expected, ...divergence},
    'reportedAt': reportedAt,
  };

  Map<String, Object?> _supervisor() => {
    'phase': awaitingRuntime
        ? 'waiting-runtime'
        : backendBusy
        ? 'compiling'
        : 'ready',
    if (target != null)
      'target': targetChanges && _inspected ? {'requested': 'web-server', 'connected': 'web-server'} : target,
    'pending': backendPending,
    if (!missingIdentity)
      'services': [
        {
          'name': 'backend',
          'phase': 'ready',
          'running': !backendStopped,
          'codeChanged': backendDirty,
          'generation': backendRestart && _inspected
              ? '00000000-0000-4000-8000-000000000002'
              : '00000000-0000-4000-8000-000000000001',
          'source': backendSourceChanges && _inspected
              ? {'current': 'b' * 64, 'applied': 'b' * 64}
              : backendDirty
              ? {'current': 'b' * 64, 'applied': 'a' * 64}
              : {'current': 'a' * 64, 'applied': 'a' * 64},
          'secret': 'PRIVATE SERVICE SENTINEL',
        },
      ],
  };

  Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
    onRequest?.call(path, data);
    switch (path) {
      case '/journey/lease':
        if (data!['operation'] == 'acquire' && leaseBusy) throw Exception('Busy');
        return {
          'id': '00000000-0000-4000-8000-000000000009',
          'phase': data['operation'] == 'finish'
              ? (data['passed'] == true && !expired ? 'idle' : 'attention')
              : 'active',
        };
      case '/journey/tap':
        return {...data!, 'status': unknownGesture ? 'unknown' : 'dispatched', 'transport': 'flutter-pointer'};
      case '/dev/status':
        return _supervisor();
      case '/moments/open':
        expect(
          data,
          journey
              ? {'name': 'review', 'prepare': true, 'fresh': true, 'journeyId': '00000000-0000-4000-8000-000000000009'}
              : {'name': 'review', 'prepare': false},
        );
        return {'revision': 'revision', 'state': _state};
      case '/moments/look':
        return {
          'revision': superseded && _inspected ? 'other' : 'revision',
          'state': _state,
          'observed': offline ? null : _observed,
          'codeChanged': dirty,
        };
      case '/moments/inspect':
        _inspected = true;
        if (declarationChanges)
          File(p.join(project, 'moments/declaration.ex')).writeAsStringSync('edited during check');
        if (sourceChanges) File(p.join(project, 'lib/view.dart')).writeAsStringSync('edited concurrently');
        return {
          'supervisor': _supervisor(),
          'moment': {'revision': 'revision', 'codeChanged': false},
          'screen': {
            'lastReported': {'matchesRevision': true, 'projection': _observed['projection']},
          },
          'backend': unavailable
              ? {'status': 'unavailable'}
              : {
                  'status': (published ?? false) ? 'changed' : 'ready',
                  'source': 'isolated-db',
                  'projection': {'transactionId': wrongEntity ? 'tx-2' : 'tx-1', 'published': published ?? false},
                },
        };
    }
    throw Exception('Unexpected request $path');
  }

  Future<Map<String, Object?>> check({
    Request? via,
    int timeout = 5,
    int poll = 1,
    bool? journey,
    bool navigation = false,
    bool profile = false,
    bool materialized = false,
  }) => checkMoment(
    project: project,
    name: 'review',
    request: via ?? request,
    timeout: timeout,
    poll: poll,
    journey: journey ?? this.journey,
    navigation: navigation,
    profile: profile,
    materialized: materialized,
  );

  Map<String, Object?> manifest() => (readJson(manifestFile)! as Map).cast();
  Map<String, Object?> get review => ((manifest()['moments']! as Map)['review']! as Map).cast();

  void edit(void Function(Map<String, Object?> review, Map<String, Object?> manifest) change) {
    final value = manifest();
    change(((value['moments']! as Map)['review']! as Map).cast(), value);
    writeJson(manifestFile, value);
  }
}

Map<String, Object?> report(Map<String, Object?> result) => (readJson(result['report']! as String)! as Map).cast();
List<Map<String, Object?>> checksOf(Map<String, Object?> value) =>
    (value['checks']! as List).cast<Map<String, Object?>>();
Map<String, Object?> ownership(Map<String, Object?> result) => (result['ownership']! as Map).cast();
Map<String, Object?> finalObservation(Map<String, Object?> result) => (result['finalObservation']! as Map).cast();
int count(List<Call> calls, String path) => calls.where((c) => c.path == path).length;

Map<String, Object?> copy(Object? value) => (jsonDecode(jsonEncode(value)) as Map).cast();

/// A journey whose single step fills an input, with UI and backend criteria.
({Fixture fixture, List<Call> calls}) filling({
  Map<String, Object?> divergence = const {},
  bool? published,
  bool sourceChanges = false,
  bool declarationChanges = false,
  bool backendRestart = false,
  bool backendSourceChanges = false,
  Map<String, Object?>? target,
  bool targetChanges = false,
}) {
  final calls = <Call>[];
  final fixture = Fixture(
    journey: true,
    divergence: divergence,
    published: published,
    sourceChanges: sourceChanges,
    declarationChanges: declarationChanges,
    backendRestart: backendRestart,
    backendSourceChanges: backendSourceChanges,
    target: target,
    targetChanges: targetChanges,
    onRequest: (path, data) => calls.add((path: path, data: data)),
  );
  fixture.edit((review, _) {
    review['steps'] = [
      {'name': 'fill', 'kind': 'fill', 'target': 'field', 'inputRef': 'fixture.value', 'until': <Object?>[]},
    ];
    review['checks'] = [
      {'name': 'finished', 'kind': 'ui_equals', 'field': 'modal', 'equals': 'done'},
      {
        'name': 'unpublished',
        'kind': 'backend_equals',
        'field': 'published',
        'equals': false,
        'match': 'transactionId',
      },
    ];
  });
  return (fixture: fixture, calls: calls);
}

Request fills(Fixture fixture, List<Call> calls, [Request? next]) {
  final inner = next ?? fixture.request;
  return (path, [data]) async {
    if (path == '/journey/fill') {
      calls.add((path: path, data: data));
      return {...data!, 'status': 'dispatched'};
    }
    return inner(path, data);
  };
}

void main() {
  test('profiling shares one preparation and gesture; missing diagnostics never repeats accepted effects', () async {
    for (final evidence in ['measured', 'missing']) {
      final calls = <Call>[];
      final fixture = Fixture(journey: true, onRequest: (path, data) => calls.add((path: path, data: data)));
      Object? gesture;
      final result = await fixture.check(
        profile: true,
        via: (path, [data]) async {
          if (path.startsWith('/journey/actions?')) {
            return {
              'version': 1,
              'journeyId': '00000000-0000-4000-8000-000000000009',
              'overflow': false,
              'receipts': evidence == 'missing'
                  ? <Object?>[]
                  : [
                      {
                        'version': 2,
                        'gesture': gesture,
                        'request': 'a' * 32,
                        'truncated': false,
                        'scope': 'request-actions-only',
                        'coverage': 'not-established',
                        'actions': <Object?>[],
                        'profile': {
                          'requestDurationUs': 1000,
                          'database': {
                            'status': 'observed',
                            'queries': 1,
                            'totalUs': 500,
                            'queryUs': 400,
                            'queueUs': 100,
                            'decodeUs': 0,
                          },
                        },
                      },
                    ],
            };
          }
          if (path == '/journey/tap') gesture = data!['id'];
          return fixture.request(path, data);
        },
      );
      expect(result['status'], 'passed');
      expect(result['exitCode'], evidence == 'measured' ? 0 : 2);
      final profile = (result['profile']! as Map).cast<String, Object?>();
      expect(profile['status'], evidence == 'measured' ? 'measured' : 'partial');
      expect(count(calls, '/moments/open'), 1);
      expect(count(calls, '/journey/tap'), 1);
      expect(ownership(result)['phase'], 'idle');
      expect(((profile['latency']! as Map)['phases']! as Map).keys, [
        'declaration',
        'ownership',
        'preparationAndRestoration',
        'steps',
        'verification',
        'finalization',
      ]);
      expect(jsonEncode(profile).contains('PRIVATE'), isFalse);
    }
  });

  test('materialized child journey reuses inherited state without open, reset or backend preparation', () async {
    final calls = <Call>[];
    final fixture = Fixture(journey: true, onRequest: (path, data) => calls.add((path: path, data: data)));
    fixture.edit((review, manifest) {
      review['from'] = 'parent';
      (manifest['moments']! as Map)['parent'] = {...review, 'from': null, 'steps': <Object?>[]};
    });
    final context = {
      'instanceId': '00000000-0000-4000-8000-000000000001',
      'moment': 'review',
      'from': 'parent',
      'manifest': sha256.convert(File(fixture.manifestFile).readAsBytesSync()).toString(),
    };
    final result = await fixture.check(
      materialized: true,
      via: (path, [data]) async {
        expect(
          ['/moments/open', '/moments/reset'].contains(path),
          isFalse,
          reason: 'A materialized journey must not move or prepare the instance',
        );
        final value = await fixture.request(path, data);
        return path == '/moments/look'
            ? {
                ...value,
                'materialization': {...context},
              }
            : value;
      },
    );
    expect(result['status'], 'passed');
    expect(ownership(result)['phase'], 'idle');
    expect(count(calls, '/journey/tap'), 1);
    expect(report(result)['materialization'], context);
    expect(report(result)['operation'], 'materialized-journey');
  });

  test(
    'materialized checker rejects an unbound actor before gestures and detects replacement after dispatch',
    () async {
      for (final mode in ['unbound', 'replaced']) {
        final calls = <Call>[];
        final fixture = Fixture(journey: true, onRequest: (path, data) => calls.add((path: path, data: data)));
        final context = {
          'instanceId': '00000000-0000-4000-8000-000000000001',
          'moment': 'review',
          'from': null,
          'manifest': sha256.convert(File(fixture.manifestFile).readAsBytesSync()).toString(),
        };
        var dispatched = false;
        final result = await fixture.check(
          materialized: true,
          via: (path, [data]) async {
            final value = await fixture.request(path, data);
            if (path == '/journey/tap') dispatched = true;
            return path == '/moments/look' && mode != 'unbound'
                ? {
                    ...value,
                    'materialization': {
                      ...context,
                      'instanceId': dispatched ? '00000000-0000-4000-8000-000000000002' : context['instanceId'],
                    },
                  }
                : value;
          },
        );
        expect(result['status'], 'unavailable');
        expect(count(calls, '/journey/tap'), mode == 'unbound' ? 0 : 1);
        expect(count(calls, '/moments/open'), 0);
        if (mode == 'replaced') expect(ownership(result)['phase'], 'attention');
      }
    },
  );

  test('final projections settle after fill without until and without replaying preparation or input', () async {
    final (:fixture, :calls) = filling();
    var inspections = 0;
    final result = await fixture.check(
      timeout: 100,
      poll: 0,
      via: fills(fixture, calls, (path, [data]) async {
        final value = copy(await fixture.request(path, data));
        if (path == '/moments/look' && inspections > 0) {
          final projection = {
            ...?((value['observed'] as Map?)?['projection'] as Map?)?.cast<String, Object?>(),
            'modal': 'done',
          };
          return {
            ...value,
            'state': {...(value['state']! as Map).cast<String, Object?>(), 'projection': projection},
            'observed': {...(value['observed']! as Map).cast<String, Object?>(), 'projection': projection},
          };
        }
        if (path == '/moments/inspect') {
          final current = inspections++;
          if (current > 0) {
            ((value['screen']! as Map)['lastReported']! as Map)['projection'] = {
              ...(((value['screen']! as Map)['lastReported']! as Map)['projection']! as Map).cast<String, Object?>(),
              'modal': 'done',
            };
          }
        }
        return value;
      }),
    );
    expect(result['status'], 'passed');
    expect(finalObservation(result)['attempts'], 2);
    expect(count(calls, '/moments/open'), 1);
    expect(count(calls, '/journey/fill'), 1);
    expect(ownership(result)['phase'], 'idle');
  });

  test('final criteria wait for backend convergence and retain only the terminal observations', () async {
    final (:fixture, :calls) = filling(divergence: {'modal': 'done'});
    var inspections = 0;
    final result = await fixture.check(
      timeout: 100,
      poll: 0,
      via: fills(fixture, calls, (path, [data]) async {
        final value = copy(await fixture.request(path, data));
        if (path == '/moments/inspect')
          ((value['backend']! as Map)['projection']! as Map)['published'] = ++inspections < 3;
        return value;
      }),
    );
    final saved = report(result);
    expect(result['status'], 'passed');
    expect(finalObservation(result)['attempts'], 3);
    expect(checksOf(saved)[1]['observed'], false);
    expect(count(calls, '/journey/fill'), 1);
    expect(jsonEncode(saved).contains('PRIVATE DRAFT SENTINEL'), isFalse);
  });

  test('a final tap with no duplicated until waits for its backend effect and dispatches once', () async {
    final (:fixture, :calls) = filling(divergence: {'modal': 'done'});
    fixture.edit((review, _) {
      review['steps'] = [
        {'name': 'submit', 'kind': 'tap', 'target': 'submit', 'until': <Object?>[]},
      ];
    });
    var inspections = 0;
    final result = await fixture.check(
      timeout: 100,
      poll: 0,
      via: fills(fixture, calls, (path, [data]) async {
        final value = copy(await fixture.request(path, data));
        if (path == '/moments/inspect')
          ((value['backend']! as Map)['projection']! as Map)['published'] = ++inspections < 2;
        return value;
      }),
    );
    expect(result['status'], 'passed');
    expect(finalObservation(result)['attempts'], 2);
    expect(count(calls, '/journey/tap'), 1);
    expect(((result['steps']! as List).first as Map)['until'], <Object?>[]);
  });

  test('a bounded final failure retains false criteria, leaves attention and does not repeat input', () async {
    final (:fixture, :calls) = filling(divergence: {'modal': 'done'}, published: true);
    final result = await fixture.check(timeout: 0, poll: 0, via: fills(fixture, calls));
    final saved = report(result);
    expect(result['status'], 'failed');
    expect(finalObservation(result)['attempts'], 1);
    expect(result['reason'], contains('deadline'));
    expect(checksOf(saved)[1]['observed'], true);
    expect(ownership(result)['phase'], 'attention');
    expect(count(calls, '/journey/fill'), 1);
  });

  test('an inconsistent final snapshot expires unavailable instead of approving partial evidence', () async {
    final (:fixture, :calls) = filling(divergence: {'modal': 'done'});
    final result = await fixture.check(
      timeout: 0,
      poll: 0,
      via: fills(fixture, calls, (path, [data]) async {
        final value = copy(await fixture.request(path, data));
        if (path == '/moments/inspect')
          ((value['screen']! as Map)['lastReported']! as Map)['projection'] = {'modal': 'other'};
        return value;
      }),
    );
    expect(result['status'], 'unavailable');
    expect(result['checks'], <Object?>[]);
    expect(result['reason'], contains('did not settle'));
    expect(ownership(result)['phase'], 'attention');
  });

  test('source, process and target changes abort final waiting instead of being retried as application lag', () async {
    for (final variant in [
      () => filling(divergence: {'modal': 'done'}, sourceChanges: true),
      () => filling(divergence: {'modal': 'done'}, declarationChanges: true),
      () => filling(divergence: {'modal': 'done'}, backendRestart: true),
      () => filling(divergence: {'modal': 'done'}, backendSourceChanges: true),
      () => filling(
        divergence: {'modal': 'done'},
        target: {'requested': 'linux', 'connected': 'linux'},
        targetChanges: true,
      ),
    ]) {
      final (:fixture, :calls) = variant();
      final result = await fixture.check(timeout: 100, poll: 0, via: fills(fixture, calls));
      expect(result['status'], 'unavailable');
      expect(finalObservation(result)['attempts'], 1);
      expect(result['checks'], <Object?>[]);
      expect(ownership(result)['phase'], 'attention');
      expect(count(calls, '/moments/inspect'), 1);
      expect(count(calls, '/journey/fill'), 1);
    }
  });

  test('a final transport error aborts with no secret payload or stale failed criteria', () async {
    final (:fixture, :calls) = filling(divergence: {'modal': 'done'}, published: true);
    var inspections = 0;
    final result = await fixture.check(
      timeout: 100,
      poll: 0,
      via: fills(fixture, calls, (path, [data]) {
        if (path == '/moments/inspect' && ++inspections == 2) throw Exception('PRIVATE OBSERVER PAYLOAD');
        return fixture.request(path, data);
      }),
    );
    expect(result['status'], 'unavailable');
    expect(result['checks'], <Object?>[]);
    expect(finalObservation(result)['attempts'], 2);
    expect((report(result)['code'] as Map?)?['backend'], isNull);
    expect(report(result).containsKey('restoration'), isFalse);
    expect(finalObservation(result)['durationMs'] as num, greaterThanOrEqualTo(0));
    expect(File(result['report']! as String).readAsStringSync().contains('PRIVATE OBSERVER PAYLOAD'), isFalse);
  });

  test('a lost Flutter identity during final convergence is not retried or confused with slow UI', () async {
    final (:fixture, :calls) = filling(divergence: {'modal': 'done'}, published: true);
    var inspections = 0;
    final result = await fixture.check(
      timeout: 100,
      poll: 0,
      via: fills(fixture, calls, (path, [data]) async {
        final value = copy(await fixture.request(path, data));
        if (path == '/moments/inspect') inspections++;
        if (path == '/moments/look' && inspections > 0) {
          value['observed'] = {...(value['observed']! as Map).cast<String, Object?>(), 'client': 'replacement'};
        }
        return value;
      }),
    );
    expect(result['status'], 'unavailable');
    expect(finalObservation(result)['attempts'], 1);
    expect(result['checks'], <Object?>[]);
    expect(ownership(result)['phase'], 'attention');
    expect(count(calls, '/journey/fill'), 1);
  });

  test('a step criterion is checked at the gesture and can differ from final UI', () async {
    final fixture = Fixture(journey: true);
    fixture.edit((review, _) {
      review['checks'] = [
        {'name': 'intermediate', 'kind': 'ui_equals', 'field': 'modal', 'equals': 'rating', 'scope': 'step'},
        {'name': 'finished', 'kind': 'ui_equals', 'field': 'modal', 'equals': 'done'},
      ];
      ((review['steps']! as List).first as Map)['until'] = ['intermediate'];
    });
    var stage = 0;
    final result = await fixture.check(
      via: (path, [data]) async {
        final value = copy(await fixture.request(path, data));
        if (path == '/journey/tap') stage = 1;
        if (path == '/moments/look' && stage == 2) {
          final observed = (value['observed']! as Map).cast<String, Object?>();
          return {
            ...value,
            'observed': {
              ...observed,
              'projection': {...(observed['projection']! as Map).cast<String, Object?>(), 'modal': 'done'},
            },
          };
        }
        if (path == '/moments/inspect') {
          if (stage == 2) {
            final reported = ((value['screen']! as Map)['lastReported']! as Map).cast<String, Object?>();
            return {
              ...value,
              'screen': {
                'lastReported': {
                  ...reported,
                  'projection': {...(reported['projection']! as Map).cast<String, Object?>(), 'modal': 'done'},
                },
              },
            };
          }
          if (stage == 1) stage = 2;
        }
        return value;
      },
    );
    final saved = report(result);
    expect(result['status'], 'passed');
    final step = ((saved['steps']! as List).first as Map).cast<String, Object?>();
    expect(checksOf(step).first['name'], 'intermediate');
    expect(checksOf(step).first['status'], 'passed');
    expect(checksOf(saved).map((c) => c['name']), ['finished']);
  });

  test('step-only or unreferenced intermediate criteria cannot produce a green proof', () async {
    for (final unused in [false, true]) {
      final fixture = Fixture(journey: true);
      fixture.edit((review, _) {
        final checks = (review['checks']! as List).cast<Map>();
        for (final check in checks) {
          check['scope'] = 'step';
        }
        if (unused) checks[1]['scope'] = 'final';
      });
      expect((await fixture.check())['status'], 'unavailable');
    }
  });

  test(
    'fresh restoration plus matching backend passes, writes private disposable evidence without draft contents',
    () async {
      final fixture = Fixture();
      final result = await fixture.check();
      expect(result['exitCode'], 0);
      expect(result['status'], 'passed');
      final file = result['report']! as String;
      expect(file.startsWith(p.join(fixture.project, 'moments/.proofs/')), isTrue);
      expect(FileStat.statSync(file).mode & 0x1ff, 0x180);
      expect(File(file).readAsStringSync().contains('PRIVATE DRAFT SENTINEL'), isFalse);
      expect(checksOf(report(result))[1]['identityMatched'], true);
      expect(
        ((((report(result)['code']! as Map)['backend']! as Map)['services']! as List).first as Map)['sourceDigest'],
        'a' * 64,
      );
      expect(File(file).readAsStringSync().contains('PRIVATE SERVICE SENTINEL'), isFalse);
      final again = await fixture.check();
      expect(again['report'], isNot(result['report']));
    },
  );

  test('actual draft mismatch fails instead of accepting same revision alone', () async {
    final result = await Fixture(divergence: {'comment': 'changed'}).check();
    expect(result['exitCode'], 1);
    expect((checksOf(report(result))[0]['observed']! as Map)['changedFields'], ['comment']);
  });

  test('published backend observation fails even when restoration is correct', () async {
    final result = await Fixture(published: true).check();
    expect(result['exitCode'], 1);
    expect(checksOf(report(result))[1]['observed'], true);
  });

  for (final MapEntry(key: name, value: make) in <String, Fixture Function()>{
    'offline': () => Fixture(offline: true),
    'backendUnavailable': () => Fixture(unavailable: true),
    'wrongEntity': () => Fixture(wrongEntity: true),
    'superseded': () => Fixture(superseded: true),
    'sourceChanged': () => Fixture(sourceChanges: true),
    'unappliedSource': () => Fixture(dirty: true),
    'noCriteria': () => Fixture(noChecks: true),
    'backendPending': () => Fixture(backendPending: true),
    'backendBusy': () => Fixture(backendBusy: true),
    'backendStopped': () => Fixture(backendStopped: true),
    'backendDirty': () => Fixture(backendDirty: true),
    'missingIdentity': () => Fixture(missingIdentity: true),
    'backendRestart': () => Fixture(backendRestart: true),
    'backendSourceChanges': () => Fixture(backendSourceChanges: true),
    'staleDeclaration': () => Fixture(staleDeclaration: true),
    'declarationChanges': () => Fixture(declarationChanges: true),
  }.entries) {
    test('$name is unavailable, never passed', () async {
      final result = await make().check();
      expect(result['exitCode'], 2);
      expect(report(result)['status'], 'unavailable');
    });
  }

  test('transport errors produce a report without leaking arbitrary error payloads', () async {
    final result = await Fixture().check(via: (path, [data]) async => throw Exception('secret token'));
    expect(result['exitCode'], 2);
    expect(File(result['report']! as String).readAsStringSync().contains('secret token'), isFalse);
  });

  test('a check uses the screen contract to bind observed identity instead of saved data', () async {
    final fixture = Fixture(divergence: {'transactionId': 'tx-2'}, wrongEntity: true);
    fixture.edit((review, manifest) {
      manifest['properties'] = {
        'modal': <String, Object?>{},
        'transactionId': {'restore': false},
      };
      (review['checks']! as List).add({
        'name': 'actual-modal',
        'kind': 'ui_equals',
        'field': 'modal',
        'equals': 'rating',
      });
    });
    final result = await fixture.check();
    expect(result['status'], 'passed');
    expect(checksOf(report(result))[1]['identitySource'], 'observed-ui');
    expect(checksOf(report(result))[2]['status'], 'passed');
  });

  test('hand-edited manifests cannot label observations as restored or compare undeclared UI fields', () async {
    for (final check in [
      {'name': 'fake', 'kind': 'restored', 'field': 'transactionId', 'equals': 'tx-1'},
      {'name': 'fake', 'kind': 'ui_equals', 'field': 'undeclared', 'equals': 'anything'},
    ]) {
      final fixture = Fixture();
      fixture.edit((review, manifest) {
        manifest['properties'] = {
          'transactionId': {'restore': false},
        };
        review['checks'] = [check];
      });
      expect((await fixture.check())['status'], 'unavailable');
    }
  });

  test('journey acquires before preparing, scopes mutations to its owner and releases only after checks', () async {
    final calls = <Call>[];
    final result = await Fixture(journey: true, onRequest: (path, data) => calls.add((path: path, data: data))).check();
    expect(result['status'], 'passed');
    expect(ownership(result)['phase'], 'idle');
    final mutations = calls.where((c) => c.data != null).toList();
    expect(mutations.map((c) => c.path), ['/journey/lease', '/moments/open', '/journey/tap', '/journey/lease']);
    expect(mutations.first.data!['operation'], 'acquire');
    expect(mutations.last.data!['passed'], true);
    expect(mutations[2].data!['journeyId'], ownership(result)['id']);
  });

  test('competing journey cannot prepare or send input', () async {
    final calls = <String>[];
    final result = await Fixture(
      journey: true,
      leaseBusy: true,
      onRequest: (path, data) {
        if (data != null) calls.add(path);
      },
    ).check();
    expect(result['status'], 'unavailable');
    expect(result['reason'], contains('exclusive journey'));
    expect(calls, ['/journey/lease']);
  });

  test('unknown gesture keeps the instance for inspection and loss of ownership prevents a passing proof', () async {
    final first = await Fixture(journey: true, unknownGesture: true).check();
    expect(first['status'], 'unavailable');
    expect(ownership(first)['phase'], 'attention');
    final expired = await Fixture(journey: true, expired: true).check();
    expect(expired['status'], 'unavailable');
    expect(expired['reason'], contains('ownership could not be released'));
  });

  test(
    'a Pub app requires the runtime to confirm the broader Dart inventory, even when old watched files match',
    () async {
      final fixture = Fixture();
      File(p.join(fixture.project, 'pubspec.yaml')).writeAsStringSync('name: app\n');
      File(p.join(fixture.project, 'pubspec.lock')).writeAsStringSync('packages: {}\n');
      writeJson(p.join(fixture.project, '.dart_tool/package_config.json'), {
        'configVersion': 2,
        'packages': [
          {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'},
        ],
      });
      final result = await fixture.check();
      expect(result['status'], 'unavailable');
      expect(result['reason'], contains('local package sources'));
    },
  );

  test('native proofs identify the actual daemon device and reject missing, wrong or changing targets', () async {
    final target = {'requested': 'linux', 'connected': 'linux'};
    final passed = await Fixture(target: target).check();
    expect(passed['status'], 'passed');
    expect(report(passed)['target'], {...target, 'source': 'flutter-daemon'});
    for (final make in [
      () => Fixture(target: {...target, 'connected': null}),
      () => Fixture(target: {...target, 'connected': 'web-server'}),
      () => Fixture(target: target, targetChanges: true),
    ]) {
      expect((await make().check())['status'], 'unavailable');
    }
  });

  test('startup waiting is unavailable with an actionable message and no gestures', () async {
    final calls = <String>[];
    final result = await Fixture(awaitingRuntime: true, journey: true, onRequest: (path, _) => calls.add(path)).check();
    expect(result['status'], 'unavailable');
    expect(result['reason'], contains('first Moment observation'));
    expect(calls.contains('/journey/tap'), isFalse);
  });

  test(
    'a changing source, backend or target cannot be called an application regression during a failed gesture',
    () async {
      for (final make in [
        () => Fixture(journey: true, published: true, sourceChanges: true),
        () => Fixture(journey: true, published: true, declarationChanges: true),
        () => Fixture(journey: true, published: true, backendRestart: true),
        () => Fixture(journey: true, published: true, backendSourceChanges: true),
        () => Fixture(
          journey: true,
          published: true,
          target: {'requested': 'linux', 'connected': 'linux'},
          targetChanges: true,
        ),
      ]) {
        final result = await make().check();
        expect(result['status'], 'unavailable');
        final step = ((result['steps']! as List).first as Map).cast<String, Object?>();
        expect(step['status'], 'unavailable');
        expect(step.containsKey('checks'), isFalse);
        expect(ownership(result)['phase'], 'attention');
        final evidence = report(result);
        expect((((evidence['code']! as Map)['backendAtStart']! as Map)['services']! as List).length, 1);
        expect((evidence['code']! as Map).containsKey('backend'), isFalse);
        expect(jsonEncode(evidence).contains('PRIVATE SERVICE SENTINEL'), isFalse);
      }
    },
  );

  test(
    'navigation accepts a Moment without criteria, captures every step and never reports business success',
    () async {
      final fixture = Fixture(journey: true, noChecks: true);
      fixture.edit((review, _) => ((review['steps']! as List).first as Map)['until'] = <Object?>[]);
      var sequence = 0, captures = 0;
      Future<Map<String, Object?>> via(String path, [Map<String, Object?>? data]) async {
        if (path == '/moments/settle') {
          captures++;
          sequence++;
          final look = await fixture.request('/moments/look');
          return {
            'status': 'captured',
            'id': '00000000-0000-4000-8000-000000000010',
            'name': 'review',
            'revision': data!['revision'],
            'client': data['client'],
            'sequence': sequence,
            'reportedAt': (look['observed']! as Map)['reportedAt'],
          };
        }
        final value = await fixture.request(path, data);
        if (path == '/moments/look') {
          return {
            ...value,
            'observed': {...(value['observed']! as Map).cast<String, Object?>(), 'captureSequence': sequence},
          };
        }
        return value;
      }

      final result = await fixture.check(navigation: true, via: via);
      expect(result['status'], 'captured');
      expect(result['exitCode'], 0);
      expect(result['checks'], <Object?>[]);
      expect(result['verification'], 'not-performed');
      expect(ownership(result)['phase'], 'idle');
      expect(captures, 2);
      expect(report(result)['operation'], 'navigation');
      final check = await fixture.check(journey: false, via: via);
      expect(check['status'], 'unavailable', reason: 'Verification still requires criteria');
    },
  );

  test('navigation without a fresh capture keeps attention and never retries a gesture', () async {
    final calls = <String>[];
    final fixture = Fixture(journey: true, noChecks: true, onRequest: (path, _) => calls.add(path));
    fixture.edit((review, _) => ((review['steps']! as List).first as Map)['until'] = <Object?>[]);
    final result = await fixture.check(
      navigation: true,
      via: (path, [data]) async => path == '/moments/settle' ? {'status': 'observed'} : fixture.request(path, data),
    );
    expect(result['status'], 'unavailable');
    expect(ownership(result)['phase'], 'attention');
    expect(calls.where((path) => path == '/journey/tap').length, 1);
    expect(result['checks'], <Object?>[]);
  });

  test('Android proof requires the exact daemon serial, not the CLI transport prefix', () async {
    final target = {'requested': 'android:emulator-5554', 'connected': 'emulator-5554'};
    final result = await Fixture(target: target).check();
    expect(result['status'], 'passed');
    expect(report(result)['target'], {...target, 'source': 'flutter-daemon'});
    for (final connected in ['emulator-5556', 'android:emulator-5554', null]) {
      expect((await Fixture(target: {...target, 'connected': connected}).check())['status'], 'unavailable');
    }
  });
}
