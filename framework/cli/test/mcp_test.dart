import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:test/test.dart';

void main() {
  test('MCP calls become agent requests; unknown calls are refused', () async {
    final requests = <Map<String, Object?>>[];
    final input = StreamController<List<int>>();
    final dir = Directory.systemTemp.createTempSync('mana-mcp-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/out');
    final output = file.openWrite();
    final served = serveMcp(
      input: input.stream,
      output: output,
      post: (request) async {
        requests.add(request);
        return request['verb'] == 'accept'
            ? (422, {'reason': 'not_offered'})
            : (200, {'entries': []});
      },
    );
    for (final message in [
      {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {}},
      {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
      {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
      {
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'entries', 'arguments': {}},
      },
      {
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'follow',
          'arguments': {'type': 'booking', 'id': 'b1', 'verb': 'accept'},
        },
      },
      {
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {'name': 'delete_everything'},
      },
      {'jsonrpc': '2.0', 'id': 6, 'method': 'nope'},
      {'jsonrpc': '2.0', 'id': 7, 'method': 'ping'},
    ]) {
      input.add(utf8.encode('${jsonEncode(message)}\n'));
    }
    input.add(utf8.encode('not json\n\n'));
    await input.close();
    await served;
    await output.close();

    final replies = [
      for (final line in file.readAsLinesSync()) jsonDecode(line) as Map,
    ];
    expect(replies.map((r) => r['id']), [1, 2, 3, 4, 5, 6, 7, null]);
    expect(replies[0]['result']['serverInfo']['name'], 'mana-agent');
    expect((replies[1]['result']['tools'] as List).map((t) => t['name']), [
      'entries',
      'open',
      'follow',
    ]);
    expect(replies[2]['result']['isError'], isFalse);
    expect(replies[3]['result']['isError'], isTrue);
    expect(replies[3]['result']['content'][0]['text'], contains('not_offered'));
    expect(replies[4]['error']['code'], -32602);
    expect(replies[5]['error']['code'], -32601);
    expect(replies[6]['result'], isEmpty);
    expect(replies[7]['error']['code'], -32700);
    expect(requests, [
      {'tool': 'entries'},
      {'tool': 'follow', 'type': 'booking', 'id': 'b1', 'verb': 'accept'},
    ]);
  });

  test('the HTTP bridge posts to /agent as the agent', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      final body = await utf8.decoder.bind(request).join();
      request.response
        ..statusCode = request.uri.path == '/agent' ? 200 : 404
        ..write(
          jsonEncode({
            'auth': request.headers.value('authorization'),
            'agent': request.headers.value('x-mana-agent'),
            'body': jsonDecode(body),
          }),
        );
      await request.response.close();
    });
    final post = httpAgentPost(
      Uri.parse('http://127.0.0.1:${server.port}/'),
      't0k',
      agent: 'planner',
    );
    final (status, body) = await post({'tool': 'entries'});
    expect(status, 200);
    expect(body, {
      'auth': 'Bearer t0k',
      'agent': 'planner',
      'body': {'tool': 'entries'},
    });
  });

  test(
    'the flat baseline exposes one tool per operation and calls it over HTTP, counted',
    () async {
      final contract = {
        'paths': {
          '/api/bookings/{id}/accept': {
            'patch': {
              'operationId': 'acceptBooking',
              'summary': 'Accept',
              'parameters': [
                {'name': 'id', 'in': 'path'},
                {'name': 'include', 'in': 'query'},
              ],
              'requestBody': {},
            },
          },
          '/api/bookings': {
            'get': {'operationId': 'listBookings'},
            'parameters': [],
          },
        },
      };
      final tools = flatTools(contract);
      expect(tools.map((t) => t['name']), ['acceptBooking', 'listBookings']);
      expect((tools.first['inputSchema']! as Map)['properties'], {
        'id': {'type': 'string', 'description': 'path parameter'},
        'include': {'type': 'string', 'description': 'query parameter'},
        'body': {'type': 'object', 'description': 'JSON:API request body'},
      });

      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = request.uri.path.endsWith('/accept') ? 200 : 422
          ..write(
            jsonEncode({
              'method': request.method,
              'path': request.uri.path,
              'query': request.uri.queryParameters,
              'type': request.headers.contentType?.mimeType,
              'body': body.isEmpty ? null : jsonDecode(body),
            }),
          );
        await request.response.close();
      });
      final dir = Directory.systemTemp.createTempSync('mana-flat-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final stats = File('${dir.path}/stats.json');
      final post = countingPost(
        httpFlatPost(Uri.parse('http://127.0.0.1:${server.port}/'), 't', tools),
        stats,
      );
      final (status, body) = await post({
        'tool': 'acceptBooking',
        'id': 'b 1',
        'include': 'service',
        'body': {'data': {}},
      });
      expect(status, 200);
      expect(body, {
        'method': 'PATCH',
        'path': '/api/bookings/b%201/accept',
        'query': {'include': 'service'},
        'type': 'application/vnd.api+json',
        'body': {'data': {}},
      });
      expect((await post({'tool': 'listBookings'})).$1, 422);
      expect((await post({'tool': 'nope'})).$1, 404);
      expect(jsonDecode(stats.readAsStringSync()), {'calls': 3, 'refused': 2});
    },
  );
}
