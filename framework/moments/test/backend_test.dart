import 'dart:convert';
import 'dart:io';

import 'package:moments/src/adapter.dart';
import 'package:moments/src/bridge.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/inspect.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Future<({int status, String text})> send(
  Bridge bridge,
  String method,
  String path, {
  Map<String, String> headers = const {},
  String? body,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(method, Uri.parse('${bridge.url}$path'));
    headers.forEach(request.headers.set);
    if (body != null) request.add(utf8.encode(body));
    final response = await request.close();
    return (status: response.statusCode, text: await utf8.decoder.bind(response).join());
  } finally {
    client.close(force: true);
  }
}

final class Renewing implements Renewal {
  var calls = 0;
  @override
  Map<String, Object?> status() => {'phase': 'idle'};
  @override
  Map<String, Object?> start(Object? name) {
    calls++;
    return {'phase': 'preparing', 'name': name};
  }

  @override
  bool canRenew(String name) => true;
}

final class Dev implements Development {
  Dev(this.renewal);
  @override
  final Renewal renewal;
  @override
  Map<String, Object?> status() => const {};
  @override
  Future<Map<String, Object?>> Function()? get inspect => null;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => null;
  @override
  Future<void> Function()? get stop => null;
}

void main() {
  test('retired runtime options fail before creating instance state', () {
    final project = temporary('moment-retired-');
    for (final key in ['dll', 'csproj', 'environment']) {
      writeJson(p.join(project, 'moments/backend.json'), {'version': 1, 'name': 'app', key: 'retired'});
      expect(
        () => Adapter.load(project),
        throwsA(predicate((e) => e is MomentsError && e.message.contains('Unknown moments/backend.json field: $key'))),
      );
      expect(Directory(p.join(project, 'moments/.backend')).existsSync(), isFalse);
    }
  });

  test('sandbox bootstrap requires local authenticated transport and never leaks into visual state', () async {
    final directory = temporary('moment-bootstrap-');
    File(p.join(directory, 'schema.json')).writeAsStringSync('{}');
    File(p.join(directory, 'overrides.json')).writeAsStringSync(' {"version":1,"values":{}}');
    final launch = {
      'apiUrl': 'http://127.0.0.1:5187',
      'account': {'email': 'fixture@moments.invalid', 'password': 'disposable'},
      'route': '/traveler/reservations',
    };
    final bridge = await Bridge.start(project: directory, port: 0, momentsEnabled: false, bootstrap: () => launch);
    addTearDown(bridge.close);
    final auth = {'Authorization': 'Bearer ${bridge.token}'};
    expect((await send(bridge, 'GET', '/moments/bootstrap')).status, 401);
    expect(
      (await send(bridge, 'GET', '/moments/bootstrap', headers: {...auth, 'Origin': 'https://outside.example'})).status,
      403,
    );
    expect(jsonDecode((await send(bridge, 'GET', '/moments/bootstrap', headers: auth)).text), launch);
    expect(
      (await send(
        bridge,
        'POST',
        '/moments/open',
        headers: {...auth, 'Content-Type': 'application/json'},
        body: '{}',
      )).status,
      404,
    );
  });

  test('renewal transport is authenticated and the bootstrap follows only committed launch data', () async {
    final directory = temporary('moment-renew-');
    File(p.join(directory, 'schema.json')).writeAsStringSync('{}');
    File(p.join(directory, 'overrides.json')).writeAsStringSync('{"version":1,"values":{}}');
    var launch = <String, Object?>{
      'account': {'password': 'local-only'},
      'projection': {'transactionId': 'old'},
    };
    final renewal = Renewing();
    final bridge = await Bridge.start(
      project: directory,
      port: 0,
      momentsEnabled: false,
      bootstrap: () => launch,
      development: Dev(renewal),
    );
    addTearDown(bridge.close);
    expect((await send(bridge, 'POST', '/dev/renew', body: '{"name":"checkout"}')).status, 401);
    final headers = {'Authorization': 'Bearer ${bridge.token}', 'Content-Type': 'application/json'};
    expect(
      (await send(
        bridge,
        'POST',
        '/dev/renew',
        headers: {...headers, 'Origin': 'https://outside.example'},
        body: '{}',
      )).status,
      403,
    );
    expect(renewal.calls, 0);
    final result = await send(bridge, 'POST', '/dev/renew', headers: headers, body: '{"name":"checkout"}');
    expect(result.status, 202);
    expect(renewal.calls, 1);
    expect(result.text.contains('local-only'), isFalse);
    launch = {
      ...launch,
      'projection': {'transactionId': 'new'},
    };
    expect(
      ((jsonDecode((await send(bridge, 'GET', '/moments/bootstrap', headers: headers)).text) as Map)['projection']
          as Map)['transactionId'],
      'new',
    );
  });
}
