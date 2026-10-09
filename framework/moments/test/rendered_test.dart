import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:moments/src/errors.dart';
import 'package:moments/src/gestures.dart';
import 'package:moments/src/http_server.dart';
import 'package:moments/src/rendered.dart';
import 'package:test/test.dart';

Map<String, Object?> report() => {
  'tracking': true,
  'truncated': false,
  'captureMs': 2,
  'nodes': [
    {
      'id': 'element_1',
      'widget': 'SizedBox',
      'location': {'file': 'file:///app/lib/view.dart', 'line': 10, 'column': 4},
      'inViewport': true,
      'reason': 'in-viewport',
      'bounds': [0, 0, 80, 20],
      'visibleBounds': [0, 0, 80, 20],
      'ancestors': <Object?>[],
      'text': 'private draft',
      'key': 'private id',
    },
  ],
  'secret': 'private',
};

final class Runtime implements ObservedMoments {
  var revision = 'r1', client = 'owner', codeHash = 'c1';
  @override
  Map<String, Object?> inspect() => {
    'revision': revision,
    'observed': {'revision': revision, 'client': client},
  };
  @override
  Map<String, Object?> checkpoint() => {'client': client, 'codeHash': codeHash};
}

typedef Answer = ({int status, Map<String, Object?>? body});

final class Fixture {
  Fixture._(this.runtime, this.port);
  final Runtime runtime;
  final int port;

  static Future<Fixture> start({int timeout = 500}) async {
    final runtime = Runtime();
    final channel = RenderedChannel(
      moments: runtime,
      timeout: Duration(milliseconds: timeout),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      try {
        await channel.handle(
          request,
          request.uri,
          () async => (jsonDecode(await utf8.decoder.bind(request).join()) as Map).cast<String, Object?>(),
        );
      } on Object catch (error) {
        reply(request.response, 400, {'error': error is MomentsError ? error.message : '$error'});
      }
    });
    addTearDown(() async {
      channel.close();
      await server.close(force: true);
    });
    return Fixture._(runtime, server.port);
  }

  Future<Answer> request(String path, [Map<String, Object?>? data]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        data == null ? 'GET' : 'POST',
        Uri.parse('http://127.0.0.1:$port/render/$path'),
      );
      if (data != null) request.add(utf8.encode(jsonEncode(data)));
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      return (
        status: response.statusCode,
        body: text.isEmpty ? null : (jsonDecode(text) as Map).cast<String, Object?>(),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<({Future<Answer> pending, Map<String, Object?> job})> capture() async {
    final next = request('next?client=owner');
    final pending = request('capture', {
      'kinds': ['SizedBox'],
    });
    return (pending: pending, job: (await next).body!);
  }

  void change(String kind) {
    if (kind == 'revision') runtime.revision = 'r2';
    if (kind == 'client') runtime.client = 'other';
    if (kind == 'code') runtime.codeHash = 'c2';
  }
}

void main() {
  test('requested capture comes from owning runtime and exposes metadata only', () async {
    final f = await Fixture.start();
    final (:pending, :job) = await f.capture();
    expect(
      (await f.request('capture', {
        'kinds': ['SizedBox'],
      })).status,
      400,
    );
    expect((await f.request('result', {...job, 'client': 'old', 'report': report()})).status, 400);
    expect((await f.request('result', {...job, 'client': 'owner', 'report': report()})).status, 200);
    final response = await pending;
    expect(response.status, 200);
    final snapshot = response.body!;
    expect((snapshot['nodes']! as List).length, 1);
    expect(snapshot['client'], 'owner');
    expect(jsonEncode(snapshot).contains('private'), isFalse);
  });

  for (final kind in ['revision', 'client', 'code']) {
    test('changed $kind invalidates a pending capture', () async {
      final f = await Fixture.start();
      final (:pending, :job) = await f.capture();
      f.change(kind);
      expect((await f.request('result', {...job, 'client': 'owner', 'report': report()})).status, 409);
      expect((await pending).status, 409);
    });
  }

  test('absent runtime times out, invalid geometry cannot be accepted', () async {
    final f = await Fixture.start(timeout: 60);
    expect(
      (await f.request('capture', {
        'kinds': ['SizedBox'],
      })).status,
      408,
    );
    final (:pending, :job) = await f.capture();
    final invalid = report();
    ((invalid['nodes']! as List).first as Map)['bounds'] = [0, 0, -1, 20];
    expect((await f.request('result', {...job, 'client': 'owner', 'report': invalid})).status, 400);
    expect((await pending).status, 422);
    final node = (report()['nodes']! as List).first;
    expect(
      () => sanitizeReport({
        ...report(),
        'nodes': [node, node],
      }),
      throwsA(predicate((e) => '$e'.contains('Invalid'))),
    );
  });
}
