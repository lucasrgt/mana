import 'dart:convert';

import 'package:mana/mana.dart' show uuidV4;
import 'package:moments/src/action_evidence.dart';
import 'package:moments/src/composition.dart';
import 'package:moments/src/errors.dart';
import 'package:test/test.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// Two login surfaces sharing one account: logging into one ends the other.
final class Fixture {
  final manifest =
      (jsonDecode(
                jsonEncode({
                  'properties': {
                    'phase': {'restore': false},
                    'actor': {'restore': false},
                  },
                  'moments': {
                    'login': {
                      'projection': {'route': '/login'},
                      'steps': [
                        {
                          'name': 'login',
                          'kind': 'tap',
                          'target': 'login',
                          'until': ['authenticated'],
                        },
                      ],
                      'checks': [
                        {'name': 'authenticated', 'kind': 'ui_equals', 'field': 'phase', 'equals': 'authenticated'},
                      ],
                    },
                    'revoked': {
                      'projection': {'route': '/login'},
                      'steps': <Object?>[],
                      'checks': [
                        {'name': 'anonymous', 'kind': 'ui_equals', 'field': 'phase', 'equals': 'anonymous'},
                        {
                          'name': 'revoked',
                          'kind': 'backend_equals',
                          'field': 'revoked',
                          'match': 'actor',
                          'equals': true,
                        },
                      ],
                    },
                    'read': {
                      'projection': {'route': '/login'},
                      'steps': [
                        {'name': 'read', 'kind': 'tap', 'target': 'read', 'until': <Object?>[]},
                      ],
                      'checks': <Object?>[],
                    },
                  },
                }),
              )
              as Map)
          .cast<String, Object?>();
  final states = {
    'a': <String, Object?>{'phase': 'anonymous', 'actor': 'a'},
    'b': <String, Object?>{'phase': 'anonymous', 'actor': 'b'},
  };
  final clients = {'a': 'client-a', 'b': 'client-b'};
  final writes = <Map<String, Object?>>[], calls = <String>[];
  late final Map<String, Object?> plan = {
    'version': 1,
    'stages': [
      step('login-a', 'a'),
      checkpoint('a-valid', 'a'),
      step('login-b', 'b'),
      checkpoint('b-valid', 'b'),
      checkpoint('a-ended', 'a', 'revoked', ['anonymous']),
    ],
  };

  List<Object?> get stages => plan['stages']! as List;
  Map<String, Object?> moment(String name) => ((manifest['moments']! as Map)[name] as Map).cast();

  Map<String, Object?> step(String id, String surface, [String moment = 'login']) => {
    'id': id,
    'surface': surface,
    'moment': moment,
    'kind': 'steps',
    'steps': [moment],
  };
  Map<String, Object?> checkpoint(String id, String surface, [String moment = 'login', List<String>? checks]) => {
    'id': id,
    'surface': surface,
    'moment': moment,
    'kind': 'checkpoint',
    'checks': ?checks,
  };

  Future<CompositionConnection> connect({required String surface, required String moment}) async =>
      CompositionConnection(
        request: (path, [data]) async {
          calls.add('$surface $path');
          if (path == '/moments/look') {
            return {
              'revision': 1,
              'observed': {
                'client': clients[surface],
                'projection': {...states[surface]!},
              },
            };
          }
          if (path == '/moments/inspect') {
            return {
              'moment': {'revision': 1},
              'screen': {
                'lastReported': {
                  'matchesRevision': true,
                  'projection': {...states[surface]!},
                },
              },
            };
          }
          writes.add({'surface': surface, ...?data});
          if (data!['target'] == 'login') {
            states[surface]!['phase'] = 'authenticated';
            states[surface == 'a' ? 'b' : 'a']!['phase'] = 'anonymous';
          }
          return {'id': data['id'], 'revision': 1, 'client': clients[surface], 'status': 'dispatched'};
        },
      );

  Future<Map<String, Object?>> run({
    Map<String, Object?>? report,
    Future<void> Function(String id)? beforeStage,
    Future<void> Function(String id)? afterStage,
    Future<CompositionConnection> Function({required String surface, required String moment})? connect,
    int timeout = 8000,
    int poll = 100,
  }) => executeComposition(
    plan: plan,
    manifest: manifest,
    connect: connect ?? this.connect,
    report: report,
    beforeStage: beforeStage,
    afterStage: afterStage,
    timeout: timeout,
    poll: poll,
  );
}

List<Map> receipts(Map<String, Object?> report) => (report['stages']! as List).cast<Map>();
List<Map> checks(Map stage) => (stage['checks']! as List).cast<Map>();

Map<String, Object?> receipt(String gesture) => {
  'version': 1,
  'gesture': gesture,
  'request': 'a' * 32,
  'truncated': false,
  'scope': 'request-actions-only',
  'coverage': 'not-established',
  'actions': [
    {'resource': 'App.Task', 'action': 'complete', 'authorization_requested': true, 'outcome': 'span-finished'},
  ],
};

Map<String, Object?> copy(Object? value) => (jsonDecode(jsonEncode(value)) as Map).cast();

void main() {
  group('composition', () {
    test('one composition preserves historical checkpoints and partial criterion coverage', () async {
      final f = Fixture(), report = <String, Object?>{};
      await f.run(report: report);
      final stages = receipts(report);
      expect(report['status'], 'passed');
      expect(f.states['a']!['phase'], 'anonymous');
      expect(checks(stages[1]).first['observed'], 'authenticated');
      expect(stages[4]['coverage'], 'selected-final-criteria');
      expect(checks(stages[4]).length, 1);
      expect(checks(stages[4]).first['observed'], 'anonymous');
      expect(f.writes.length, 2);
      expect(f.writes[0]['id'], isNot(f.writes[1]['id']));
      expect(report['manifestDigest'], matches(RegExp(r'^[a-f0-9]{64}$')));
    });

    test('all references are checked before any connection or gesture', () async {
      for (final mutate in <void Function(Fixture f)>[
        (f) => f.stages.add({
          ...(f.stages.first! as Map).cast<String, Object?>(),
          'id': 'unknown',
          'steps': ['missing'],
        }),
        (f) => ((f.stages[4]! as Map)['checks'] as List).add('made_up'),
        (f) => (f.stages[0]! as Map)['target'] = 'replacement',
        (f) => (f.stages[0]! as Map)['checks'] = <Object?>[],
        (f) => (f.stages[1]! as Map)['steps'] = <Object?>[],
        (f) => f.plan['from'] = 'new-parent',
        (f) => (f.stages[4]! as Map)['checks'] = <Object?>[],
        (f) => ((f.stages[0]! as Map)['steps'] as List).add('login'),
      ]) {
        final f = Fixture();
        mutate(f);
        await expectLater(f.run(), throwsA(anything));
        expect(f.calls, isEmpty);
        expect(f.writes, isEmpty);
      }
    });

    test('replaced runtime fails before the next gesture and never silently rebinds', () async {
      final f = Fixture(), report = <String, Object?>{};
      f.plan['stages'] = [f.step('first', 'a'), f.step('second', 'a')];
      await expectLater(
        f.run(
          report: report,
          afterStage: (id) async {
            if (id == 'first') f.clients['a'] = 'replacement';
          },
        ),
        throwing('changed between'),
      );
      expect(f.writes.length, 1);
      expect(report['status'], 'unavailable');
      expect(receipts(report).first['status'], 'passed');
    });

    test('two aliases cannot accidentally drive the same client', () async {
      final f = Fixture();
      f.clients['b'] = f.clients['a']!;
      await expectLater(f.run(), throwing('distinct runtime'));
      expect(f.writes.length, 1);
    });

    test('lost dispatch receipt stops the plan without replay or invented approval', () async {
      final f = Fixture(), report = <String, Object?>{};
      var attempts = 0;
      Future<CompositionConnection> connect({required String surface, required String moment}) async {
        final inner = await f.connect(surface: surface, moment: moment);
        return CompositionConnection(
          request: (path, [data]) {
            if (path.startsWith('/journey/')) {
              attempts++;
              throw const MomentsError('private diagnostic');
            }
            return inner.request(path, data);
          },
        );
      }

      await expectLater(f.run(connect: connect, report: report), throwing('private diagnostic'));
      expect(attempts, 1);
      expect(receipts(report).length, 1);
      expect(report['status'], 'unavailable');
      expect(((receipts(report).first['steps'] as List).first as Map)['dispatch'], 'unknown');
      expect(jsonEncode(report).contains('private diagnostic'), isFalse);
    });

    test('failed final checkpoint keeps earlier evidence but fails composition', () async {
      final f = Fixture(), report = <String, Object?>{};
      f.stages.add(f.checkpoint('a-still-logged-in', 'a'));
      await expectLater(f.run(report: report, timeout: 5, poll: 1), throwing('not reached'));
      expect(report['status'], 'failed');
      expect(receipts(report)[1]['status'], 'passed');
      expect(receipts(report).last['status'], 'failed');
    });

    test('dispatch without until is not final-criterion coverage', () async {
      final f = Fixture(), report = <String, Object?>{};
      f.plan['stages'] = [f.step('read', 'a', 'read')];
      await f.run(report: report);
      final stage = receipts(report).first;
      expect(stage['coverage'], 'declared-step-postconditions');
      final step = ((stage['steps'] as List).first as Map).cast<String, Object?>();
      expect(step.containsKey('checks'), isFalse);
      expect(step['meaning'], contains('Operation dispatched'));
    });

    test('declarations are snapshotted before callbacks can modify them', () async {
      final f = Fixture();
      await f.run(
        beforeStage: (_) async {
          ((f.moment('login')['steps']! as List).first as Map)['target'] = 'injected';
          f.stages.clear();
        },
      );
      expect(f.writes.every((w) => w['target'] == 'login'), isTrue);
    });

    test('restoration checks and reordered steps require their own valid execution path', () {
      final f = Fixture();
      (f.moment('login')['checks']! as List).add({'name': 'restored', 'kind': 'restored'});
      expect(() => compileComposition(f.plan, f.manifest), throwing('Restoration'));
      (f.moment('login')['checks']! as List).removeLast();
      (f.moment('login')['steps']! as List).add({
        'name': 'later',
        'kind': 'tap',
        'target': 'later',
        'until': <Object?>[],
      });
      (f.stages[0]! as Map)['steps'] = ['later', 'login'];
      expect(() => compileComposition(f.plan, f.manifest), throwing('declaration order'));
    });
  });

  group('action evidence', () {
    final gesture = uuidV4(), journeyId = uuidV4();

    test('only allowlisted receipts become positive observations, not assertion coverage', () {
      final value = actionEvidence(
        {
          'version': 1,
          'journeyId': journeyId,
          'overflow': false,
          'receipts': [receipt(gesture)],
        },
        [
          {'id': gesture, 'name': 'complete'},
        ],
        journeyId,
      );
      expect(value['status'], 'observed');
      expect(value['coverage'], 'not-established');
      expect(((value['receipts']! as List).first as Map)['step'], 'complete');
      expect(
        actionEvidence(
          {'version': 1, 'journeyId': journeyId, 'overflow': false, 'receipts': <Object?>[]},
          const [],
          journeyId,
        )['status'],
        'not-observed',
      );
    });

    test('credential fields, malformed names, cross-journey gestures and duplicates are refused', () {
      Map action(Map<String, Object?> r) => (r['actions']! as List).first as Map;
      for (final mutate in <void Function(Map<String, Object?> r)>[
        (r) => r['token'] = 'secret',
        (r) => action(r)['actor'] = 'secret',
        (r) => action(r)['resource'] = '../../secret',
        (r) => action(r)['outcome'] = 'passed',
        (r) => r['actions'] = List.filled(17, action(r)),
      ]) {
        final r = receipt(gesture);
        mutate(r);
        expect(() => actionReceipt(r), throwing('Invalid action evidence'));
      }
      final value = {
        'version': 1,
        'journeyId': journeyId,
        'overflow': false,
        'receipts': [receipt(gesture)],
      };
      expect(
        () => actionEvidence(value, [
          {'id': uuidV4(), 'name': 'other'},
        ], journeyId),
        throwsA(anything),
      );
      expect(
        () => actionEvidence(
          {
            ...value,
            'receipts': [receipt(gesture), receipt(gesture)],
          },
          [
            {'id': gesture, 'name': 'complete'},
          ],
          journeyId,
        ),
        throwsA(anything),
      );
      expect(
        () => actionEvidence(value, [
          {'id': gesture, 'name': 'complete'},
        ], uuidV4()),
        throwsA(anything),
      );
    });

    test('versioned profiles reject payloads, unknown fields and invalid units without changing v1 compatibility', () {
      final v2 = {
        ...receipt(gesture),
        'version': 2,
        'profile': {
          'requestDurationUs': 1234,
          'database': {
            'status': 'observed',
            'queries': 2,
            'totalUs': 900,
            'queryUs': 800,
            'queueUs': 100,
            'decodeUs': 0,
          },
        },
      };
      ((v2['actions']! as List).first as Map)['durationUs'] = 1000;
      expect(actionReceipt(v2), v2);
      expect(actionReceipt(receipt(gesture))['version'], 1);
      Map database(Map<String, Object?> r) => (r['profile']! as Map)['database'] as Map;
      for (final mutate in <void Function(Map<String, Object?> r)>[
        (r) => database(r)['sql'] = 'private',
        (r) => (r['profile']! as Map)['requestDurationUs'] = -1,
        (r) => database(r)['totalUs'] = double.infinity,
        (r) => ((r['actions']! as List).first as Map)['durationUs'] = 0.5,
        (r) => database(r)['queries'] = 0,
        (r) => r['version'] = 1,
      ]) {
        final r = copy(v2);
        mutate(r);
        expect(() => actionReceipt(r), throwsA(anything));
      }
    });

    test('v3 receipts name the records a request changed, by field name only', () {
      final v3 = {
        ...receipt(gesture),
        'version': 3,
        'profile': {
          'requestDurationUs': 10,
          'database': {'status': 'not-observed'},
        },
        'changes': [
          {
            'resource': 'Example.Operations.Booking',
            'subject': '6f1c2a0e-1b2c-4d3e-8f90-123456789abc',
            'action': 'accept',
            'outcome': 'done',
            'fields': ['status', 'accepted_at'],
          },
        ],
      };
      expect(actionReceipt(v3)['changes'], v3['changes']);
      Map change(Map<String, Object?> r) => (r['changes']! as List).first as Map;
      for (final mutate in <void Function(Map<String, Object?> r)>[
        (r) => change(r)['before'] = {'status': 'requested'},
        (r) => change(r)['fields'] = ['Status value'],
        (r) => change(r)['outcome'] = 'maybe',
        (r) => change(r)['subject'] = '',
        (r) => r['changes'] = [],
        (r) => r['version'] = 2,
      ]) {
        final r = copy(v3);
        mutate(r);
        expect(() => actionReceipt(r), throwsA(anything));
      }
    });
  });
}
