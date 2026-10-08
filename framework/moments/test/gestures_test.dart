import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;
import 'package:moments/src/check.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/gestures.dart';
import 'package:moments/src/http_server.dart';
import 'package:moments/src/journey.dart';
import 'package:moments/src/timing.dart';
import 'package:test/test.dart';

final class State implements GestureMoments {
  var revision = 'revision', client = 'runtime', codeHash = 'hash', codeChanged = false;
  Map<String, Object?> get _value => {
    'revision': revision,
    'client': client,
    'codeHash': codeHash,
    'codeChanged': codeChanged,
  };
  @override
  Map<String, Object?> inspect() => {
    ..._value,
    'observed': {'revision': revision, 'client': client},
  };
  @override
  Map<String, Object?> checkpoint() => _value;
  @override
  bool inputAllowed(String reference, String target, [String kind = 'fill']) => kind == 'fill'
      ? reference == 'fixture.password' && target == 'secret-field'
      : reference == 'fixture.item' && target == 'item-';
}

typedef Answer = ({int status, Map<String, Object?>? data});

final class Fixture {
  Fixture._(this.state, this.channel, this.port);
  final State state;
  final GestureChannel channel;
  final int port;

  static Future<Fixture> start({
    int timeout = 300,
    void Function(Object? journeyId)? authorize,
    String Function(String reference)? resolveInput,
    void Function(Map<String, Object?> dispatch)? onDispatch,
  }) async {
    final state = State();
    final channel = GestureChannel(
      moments: state,
      timeout: Duration(milliseconds: timeout),
      authorize: authorize,
      resolveInput: resolveInput,
      onDispatch: onDispatch,
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        final handled = await channel.handle(
          request,
          request.uri,
          () async => (jsonDecode(await utf8.decoder.bind(request).join()) as Map).cast<String, Object?>(),
        );
        if (!handled) reply(request.response, 404, {'error': 'Unknown'});
      } on Object catch (error) {
        reply(request.response, 400, {'error': error is MomentsError ? error.message : '$error'});
      }
    });
    addTearDown(() async {
      channel.close();
      await server.close(force: true);
    });
    return Fixture._(state, channel, server.port);
  }

  Future<Answer> request(String path, [Map<String, Object?>? data, Duration? timeout]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        data != null ? 'POST' : 'GET',
        Uri.parse('http://127.0.0.1:$port/journey/$path'),
      );
      if (data != null) request.add(utf8.encode(jsonEncode(data)));
      final response = await (timeout != null ? request.close().timeout(timeout) : request.close());
      final text = await utf8.decoder.bind(response).join();
      return (
        status: response.statusCode,
        data: response.statusCode == 204 ? null : (jsonDecode(text) as Map).cast<String, Object?>(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Map<String, Object?> input() => {
    'id': uuidV4(),
    'revision': state.revision,
    'client': state.client,
    'target': 'notification-id',
  };
}

void main() {
  test('action receipts require a dispatched gesture, the same runtime and active journey ownership', () async {
    final journeyId = uuidV4();
    var active = true;
    final f = await Fixture.start(
      timeout: 1000,
      authorize: (id) {
        if (!active || id != journeyId) throw const MomentsError('Wrong lease');
      },
    );
    final input = {...f.input(), 'journeyId': journeyId};
    final receipt = {
      'version': 1,
      'gesture': input['id'],
      'request': 'b' * 32,
      'truncated': false,
      'scope': 'request-actions-only',
      'coverage': 'not-established',
      'actions': [
        {'resource': 'App.Task', 'action': 'complete', 'outcome': 'span-finished', 'authorization_requested': true},
      ],
    };
    expect((await f.request('actions', {...input, 'receipt': receipt})).status, 400);
    final action = f.request('tap', input);
    await f.request('next?client=runtime');
    expect(
      (await f.request('actions', {
        ...input,
        'receipt': {...receipt, 'token': 'PRIVATE'},
      })).status,
      400,
    );
    expect((await f.request('actions', {...input, 'receipt': receipt})).status, 200);
    expect((await f.request('actions', {...input, 'receipt': receipt})).status, 400);
    await f.request('result', {...input, 'outcome': 'dispatched'});
    expect((await action).data!['status'], 'dispatched');
    final evidence = await f.request('actions?journeyId=$journeyId');
    expect((evidence.data!['receipts']! as List).length, 1);
    expect(jsonEncode(evidence.data).contains('PRIVATE'), isFalse);
    expect((await f.request('actions?journeyId=${uuidV4()}')).status, 400);
    f.state.client = 'replacement';
    expect(
      (await f.request('actions', {
        ...input,
        'receipt': {...receipt, 'request': 'c' * 32},
      })).status,
      400,
    );
    active = false;
    expect((await f.request('actions?journeyId=$journeyId')).status, 400);
  });

  test('a new owned journey starts a fresh evidence budget and rejects late receipts from the old journey', () async {
    var owner = uuidV4();
    final f = await Fixture.start(
      timeout: 1000,
      authorize: (id) {
        if (id != owner) throw const MomentsError('Wrong lease');
      },
    );
    Future<Map<String, Object?>> dispatch() async {
      final input = {...f.input(), 'journeyId': owner};
      final action = f.request('tap', input);
      await f.request('next?client=runtime');
      await f.request('result', {...input, 'outcome': 'dispatched'});
      await action;
      return input;
    }

    final old = await dispatch();
    final receipt = {
      'version': 1,
      'gesture': old['id'],
      'request': 'd' * 32,
      'truncated': false,
      'scope': 'request-actions-only',
      'coverage': 'not-established',
      'actions': <Object?>[],
    };
    expect((await f.request('actions', {...old, 'receipt': receipt})).status, 200);
    owner = uuidV4();
    await dispatch();
    expect((await f.request('actions?journeyId=$owner')).data!['receipts'], <Object?>[]);
    expect(
      (await f.request('actions', {
        ...old,
        'receipt': {...receipt, 'request': 'e' * 32},
      })).status,
      400,
    );
  });

  test('a gesture is handed out once and an operation id cannot be reused', () async {
    final f = await Fixture.start(), input = f.input();
    final action = f.request('tap', input);
    final next = await f.request('next?client=runtime');
    expect(next.data!['id'], input['id']);
    await expectLater(
      f.request('next?client=runtime', null, const Duration(milliseconds: 30)),
      throwsA(isA<TimeoutException>()),
    );
    await f.request('result', {
      ...input,
      'outcome': 'dispatched',
      'timing': {'clock': 'dart-monotonic', 'frameMs': 1, 'executeMs': 2, 'totalMs': 3, 'secret': 'PRIVATE-DIAGNOSTIC'},
    });
    final result = (await action).data!;
    expect(result['status'], 'dispatched');
    expect(result['transport'], 'flutter-pointer');
    final timing = (result['timing']! as Map).cast<String, Object?>();
    expect((timing['runtime']! as Map)['executeMs'], 2);
    expect(timing['queueMs'] as num, greaterThanOrEqualTo(0));
    expect(timing['deliveryToReceiptMs'] as num, greaterThanOrEqualTo(0));
    expect(jsonEncode(result).contains('PRIVATE-DIAGNOSTIC'), isFalse);
    expect((await f.request('tap', input)).status, 400);
  });

  test('malformed advisory timing is discarded instead of changing dispatch outcome', () {
    for (final value in <Object?>[
      null,
      {'clock': 'wall', 'frameMs': 0, 'executeMs': 0, 'totalMs': 0},
      {'clock': 'dart-monotonic', 'frameMs': -1, 'executeMs': 0, 'totalMs': 0},
      {'clock': 'dart-monotonic', 'frameMs': 10, 'executeMs': 10, 'totalMs': 1},
      {'clock': 'dart-monotonic', 'frameMs': 0, 'executeMs': double.infinity, 'totalMs': 1},
    ]) {
      expect(sanitizeGestureTiming(value), isNull, reason: '$value');
    }
  });

  test('fill resolves a declared input once, sends it only to the runtime and redacts its receipt', () async {
    var resolutions = 0;
    const secret = 'PRIVATE-FIXTURE-ONLY';
    final f = await Fixture.start(
      resolveInput: (_) {
        resolutions++;
        return secret;
      },
    );
    final input = {...f.input(), 'target': 'secret-field', 'inputRef': 'fixture.password'};
    expect((await f.request('fill', {...input, 'inputRef': 'arbitrary.environment'})).status, 400);
    expect((await f.request('fill', {...input, 'text': secret})).status, 400);
    expect((await f.request('fill', {...input, 'target': 'another-field'})).status, 400);
    expect(resolutions, 0);
    final action = f.request('fill', input);
    final delivered = await f.request('next?client=runtime');
    expect(delivered.data!['kind'], 'fill');
    expect(delivered.data!['text'], secret);
    await f.request('result', {...input, 'outcome': 'dispatched'});
    final receipt = (await action).data!;
    expect(receipt['transport'], 'flutter-text-input');
    expect(jsonEncode(receipt).contains(secret), isFalse);
    expect((await f.request('fill', input)).status, 400);
    expect(resolutions, 1);
  });

  test('a tap with a declared input aims at the prefix plus that input, never a raw target', () async {
    final f = await Fixture.start(resolveInput: (_) => '42');
    final input = {...f.input(), 'target': 'item-', 'inputRef': 'fixture.item'};
    expect((await f.request('tap', {...input, 'inputRef': 'fixture.password'})).status, 400);
    final action = f.request('tap', input);
    final delivered = await f.request('next?client=runtime');
    expect(delivered.data!['target'], 'item-42');
    await f.request('result', {...input, 'outcome': 'dispatched'});
    expect((await action).data!['status'], 'dispatched');
    final unsafe = await Fixture.start(resolveInput: (_) => 'bad target!');
    expect(
      (await unsafe.request('tap', {...unsafe.input(), 'target': 'item-', 'inputRef': 'fixture.item'})).status,
      400,
    );
    expect(unsafe.channel.pending(), isFalse);
  });

  test('explicit reveal uses the same single-use runtime fence without resolving private input', () async {
    final f = await Fixture.start(resolveInput: (_) => throw const MomentsError('Reveal must not resolve credentials'));
    final input = f.input(), action = f.request('reveal', input);
    final delivered = await f.request('next?client=runtime');
    expect(delivered.data!['kind'], 'reveal');
    expect(delivered.data!.containsKey('text'), isFalse);
    await f.request('result', {...input, 'outcome': 'dispatched'});
    expect((await action).data!['transport'], 'flutter-scroll');
    expect((await f.request('reveal', input)).status, 400);
    f.state.codeChanged = true;
    expect((await f.request('reveal', f.input())).status, 400);
  });

  test('resolver exceptions cannot expose private input or leave a pending gesture', () async {
    const secret = 'PRIVATE-RESOLVER-DETAIL';
    final f = await Fixture.start(resolveInput: (_) => throw Exception(secret));
    final result = await f.request('fill', {...f.input(), 'target': 'secret-field', 'inputRef': 'fixture.password'});
    expect(result.status, 400);
    expect(jsonEncode(result.data).contains(secret), isFalse);
    expect(f.channel.pending(), isFalse);
  });

  test('input dispatch alone cannot certify a journey by restoring its own expected state', () {
    final steps = [
      {'name': 'fill', 'kind': 'fill', 'target': 'field', 'inputRef': 'fixture.value', 'until': <Object?>[]},
    ];
    expect(
      () => validateSteps({
        'steps': steps,
        'checks': [
          {'name': 'restored', 'kind': 'restored'},
        ],
      }),
      throwsA(predicate((e) => '$e'.contains('observed UI or backend criterion'))),
    );
    validateSteps({
      'steps': steps,
      'checks': [
        {'name': 'validated', 'kind': 'ui_equals', 'field': 'valid', 'equals': true},
      ],
    });
  });

  test('a final tap uses final criteria, while intermediate taps still declare their transition', () {
    final tap = {'name': 'press', 'kind': 'tap', 'target': 'button', 'until': <Object?>[]};
    final checks = [
      {'name': 'finished', 'kind': 'ui_equals', 'field': 'valid', 'equals': true},
    ];
    validateSteps({
      'steps': [tap],
      'checks': checks,
    });
    expect(
      () => validateSteps({
        'steps': [
          tap,
          {'name': 'fill', 'kind': 'fill', 'target': 'field', 'inputRef': 'fixture.value', 'until': <Object?>[]},
        ],
        'checks': checks,
      }),
      throwsA(predicate((e) => '$e'.contains('postcondition'))),
    );
    expect(
      () => validateSteps({
        'steps': [tap],
        'checks': [
          {'name': 'restored', 'kind': 'restored'},
        ],
      }),
      throwsA(predicate((e) => '$e'.contains('observed UI or backend criterion'))),
    );
  });

  test('lost response after delivery is unknown, not success or permission to replay', () async {
    final f = await Fixture.start(timeout: 50), input = f.input();
    final action = f.request('tap', input);
    await f.request('next?client=runtime');
    expect((await action).data!['status'], 'unknown');
    expect((await f.request('result', {...input, 'outcome': 'dispatched'})).status, 400);
    expect((await f.request('tap', input)).status, 400);
  });

  test('runtime replacement retires the in-flight gesture with uncertain outcome', () async {
    final f = await Fixture.start(), input = f.input();
    final action = f.request('tap', input);
    await f.request('next?client=runtime');
    f.state.client = 'replacement';
    f.channel.retireOthers('replacement');
    expect((await action).data!['status'], 'unknown');
    expect((await f.request('next?client=runtime')).status, 409);
  });

  test('source drift and inactive runtime are rejected before sending input', () async {
    final f = await Fixture.start();
    f.state.codeChanged = true;
    expect((await f.request('tap', f.input())).status, 400);
    f.state.codeChanged = false;
    expect((await f.request('tap', {...f.input(), 'client': 'old'})).status, 400);
  });

  final scene = {
    'steps': [
      {
        'name': 'read',
        'kind': 'tap',
        'target': 'notification-id',
        'until': ['read', 'consistent'],
      },
    ],
    'checks': [
      {'name': 'read', 'kind': 'backend_equals', 'field': 'read', 'equals': true, 'match': 'ids'},
      {'name': 'consistent', 'kind': 'backend_equals', 'field': 'storage', 'equals': 'db', 'match': 'readIds'},
    ],
  };

  test('journey waits for both durable write and UI refetch while sending exactly one gesture', () async {
    var taps = 0, reads = 0;
    final report = <String, Object?>{};
    Map<String, Object?> projection() => {'route': '/inbox', 'ids': 'id', 'readIds': reads >= 3 ? 'id' : 'none'};
    Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
      if (path == '/journey/tap') {
        taps++;
        return {...data!, 'status': 'dispatched', 'transport': 'flutter-pointer'};
      }
      if (path == '/moments/look') {
        reads++;
        return {
          'revision': 'r',
          'observed': {'client': 'c', 'projection': projection()},
        };
      }
      if (path == '/moments/inspect') {
        return {
          'moment': {'revision': 'r'},
          'screen': {
            'lastReported': {'matchesRevision': true, 'projection': projection()},
          },
          'backend': {
            'status': 'ready',
            'projection': {'ids': 'id', 'readIds': reads >= 2 ? 'id' : 'none', 'read': reads >= 2, 'storage': 'db'},
          },
        };
      }
      throw Exception('Unexpected operation');
    }

    validateSteps(scene);
    await executeSteps(
      scene: scene,
      request: request,
      revision: 'r',
      client: 'c',
      expected: {'route': '/inbox'},
      properties: {
        'ids': {'restore': false},
        'readIds': {'restore': false},
      },
      evaluate: evaluateChecks,
      report: report,
      poll: 1,
    );
    expect(taps, 1);
    expect(reads, 3);
    expect(((report['steps']! as List).first as Map)['status'], 'passed');
  });

  test('a lost gesture receipt ends the journey without a second attempt', () async {
    var calls = 0;
    final report = <String, Object?>{};
    await expectLater(
      executeSteps(
        scene: scene,
        request: (path, [data]) async {
          calls++;
          throw Exception('Connection lost');
        },
        revision: 'r',
        client: 'c',
        expected: <String, Object?>{},
        properties: null,
        evaluate: evaluateChecks,
        report: report,
      ),
      throwsA(predicate((e) => '$e'.contains('Connection lost'))),
    );
    expect(calls, 1);
    expect(((report['steps']! as List).first as Map)['dispatch'], 'unknown');
  });

  test('dispatch journal receives only metadata before credentials reach the runtime', () async {
    Map<String, Object?>? recorded;
    final f = await Fixture.start(
      resolveInput: (_) => 'PRIVATE-INPUT',
      onDispatch: (operation) => recorded = operation,
    );
    final input = {...f.input(), 'target': 'secret-field', 'inputRef': 'fixture.password', 'journeyId': 'owner'};
    final action = f.request('fill', input);
    final delivered = await f.request('next?client=runtime');
    expect(recorded, {'journeyId': 'owner', 'id': input['id'], 'kind': 'fill', 'target': 'secret-field'});
    expect(delivered.data!['text'], 'PRIVATE-INPUT');
    await f.request('result', {...input, 'outcome': 'dispatched'});
    expect((await action).data!['status'], 'dispatched');
  });

  test('journal failure rejects the gesture without delivering or retrying it', () async {
    var attempts = 0;
    final f = await Fixture.start(
      onDispatch: (_) {
        attempts++;
        throw Exception('private filesystem detail');
      },
    );
    final input = f.input(), action = f.request('tap', input);
    final poll = f.request('next?client=runtime', null, const Duration(milliseconds: 50));
    final failed = await action;
    expect(failed.data!['status'], 'rejected');
    expect(failed.data!['delivered'], false);
    expect(jsonEncode(failed.data).contains('private filesystem detail'), isFalse);
    await expectLater(poll, throwsA(isA<TimeoutException>()));
    expect(attempts, 1);
    expect(f.channel.pending(), isFalse);
    expect((await f.request('tap', input)).status, 400);
  });
}
