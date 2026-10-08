import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Calls the app's agent endpoint (`Mana.Agent.Plug`) with one tool call;
/// answers the HTTP status and the decoded JSON body.
typedef AgentPost =
    Future<(int, Object?)> Function(Map<String, Object?> request);

/// The tools an agent gets: the app's screens and verbs, not its endpoints.
const mcpTools = [
  {
    'name': 'entries',
    'description':
        'Lists the entries (screens) you can open, each with what it shows.',
    'inputSchema': {'type': 'object', 'properties': <String, Object>{}},
  },
  {
    'name': 'open',
    'description':
        'Opens an entry: its records in that view, each with the verbs it '
        'offers you now and their inputs. Only offered verbs can be followed.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'entry': {'type': 'string', 'description': 'e.g. booking.agenda_card'},
        'arguments': {'type': 'object'},
      },
      'required': ['entry'],
    },
  },
  {
    'name': 'follow',
    'description':
        'Performs a verb a record offers, with its inputs; answers the record '
        'after and what it offers next, or why it was refused.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'type': {'type': 'string'},
        'id': {'type': 'string'},
        'verb': {'type': 'string'},
        'params': {'type': 'object'},
      },
      'required': ['type', 'id', 'verb'],
    },
  },
];

/// The baseline agents usually get: one tool per HTTP operation of the
/// [contract] (OpenAPI), named by its operationId, taking its path and
/// query parameters and a JSON body.
List<Map<String, Object?>> flatTools(Map contract) => [
  for (final MapEntry(key: path, value: methods)
      in (contract['paths'] as Map).entries)
    for (final MapEntry(key: method, value: operation)
        in (methods as Map).entries)
      if (operation is Map && operation['operationId'] is String)
        {
          'name': operation['operationId'],
          'description':
              '${'$method'.toUpperCase()} $path${operation['summary'] is String ? ' — ${operation['summary']}' : ''}',
          'inputSchema': {
            'type': 'object',
            'properties': {
              for (final param
                  in ((operation['parameters'] as List?) ?? const [])
                      .cast<Map>())
                '${param['name']}': {
                  'type': 'string',
                  'description': '${param['in']} parameter',
                },
              if (operation['requestBody'] != null)
                'body': {
                  'type': 'object',
                  'description': 'JSON:API request body',
                },
            },
          },
          '_method': '$method'.toUpperCase(),
          '_path': path,
          '_query': [
            for (final param
                in ((operation['parameters'] as List?) ?? const []).cast<Map>())
              if (param['in'] == 'query') '${param['name']}',
          ],
        },
];

/// An [AgentPost] for [flatTools]: calls the operation over HTTP.
AgentPost httpFlatPost(
  Uri api,
  String token,
  List<Map<String, Object?>> tools,
) {
  final client = HttpClient();
  return (request) async {
    final tool = tools.where((t) => t['name'] == request['tool']).firstOrNull;
    if (tool == null) return (404, {'reason': 'no_such_tool'});
    var path = tool['_path']! as String;
    final query = <String, String>{};
    for (final MapEntry(:key, :value) in request.entries) {
      if (path.contains('{$key}')) {
        path = path.replaceAll('{$key}', Uri.encodeComponent('$value'));
      } else if ((tool['_query']! as List).contains(key)) {
        query[key] = '$value';
      }
    }
    final call = await client.openUrl(
      tool['_method']! as String,
      api.resolve(path).replace(queryParameters: query.isEmpty ? null : query),
    );
    call.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/vnd.api+json')
      ..set(HttpHeaders.acceptHeader, 'application/vnd.api+json')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token');
    if (request['body'] != null) call.write(jsonEncode(request['body']));
    final response = await call.close();
    final text = await response.transform(utf8.decoder).join();
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    return (response.statusCode, body);
  };
}

/// Wraps [post] to count calls and refusals into [file] (JSON), for
/// comparing how agents fare with different tool shapes.
AgentPost countingPost(AgentPost post, File file) {
  var calls = 0, refused = 0;
  return (request) async {
    final (status, body) = await post(request);
    calls++;
    if (status >= 400) refused++;
    file.writeAsStringSync(jsonEncode({'calls': calls, 'refused': refused}));
    return (status, body);
  };
}

/// Serves MCP over newline-delimited JSON-RPC on [input]/[output], turning
/// each tool call into a [post] to the app. [tools] defaults to the
/// open/follow tools ([mcpTools]).
Future<void> serveMcp({
  required Stream<List<int>> input,
  required IOSink output,
  required AgentPost post,
  List<Map<String, Object?>> tools = mcpTools,
}) async {
  await for (final line
      in input.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.trim().isEmpty) continue;
    final Map message;
    try {
      message = jsonDecode(line) as Map;
    } on FormatException {
      _send(output, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'parse error'},
      });
      continue;
    }
    final id = message['id'];
    if (id == null) continue;
    final reply = await _answer(message, post, tools);
    _send(output, {'jsonrpc': '2.0', 'id': id, ...reply});
  }
}

Future<Map<String, Object?>> _answer(
  Map message,
  AgentPost post,
  List<Map<String, Object?>> tools,
) async {
  switch (message['method']) {
    case 'initialize':
      return {
        'result': {
          'protocolVersion':
              (message['params'] as Map?)?['protocolVersion'] ?? '2025-06-18',
          'capabilities': {'tools': <String, Object>{}},
          'serverInfo': {'name': 'mana-agent', 'version': '0.1.0'},
        },
      };
    case 'ping':
      return {'result': <String, Object>{}};
    case 'tools/list':
      return {
        'result': {
          'tools': [
            for (final tool in tools)
              {
                for (final e in tool.entries)
                  if (!e.key.startsWith('_')) e.key: e.value,
              },
          ],
        },
      };
    case 'tools/call':
      final params = (message['params'] as Map?) ?? const {};
      final name = params['name'];
      if (!tools.any((t) => t['name'] == name)) {
        return {
          'error': {'code': -32602, 'message': 'unknown tool $name'},
        };
      }
      final (status, body) = await post({
        'tool': name,
        ...((params['arguments'] as Map?)?.cast<String, Object?>() ?? {}),
      });
      return {
        'result': {
          'content': [
            {'type': 'text', 'text': jsonEncode(body)},
          ],
          'isError': status >= 400,
        },
      };
    default:
      return {
        'error': {
          'code': -32601,
          'message': 'method not found: ${message['method']}',
        },
      };
  }
}

void _send(IOSink output, Map<String, Object?> message) =>
    output.writeln(jsonEncode(message));

/// An [AgentPost] over HTTP to `<api>/agent` with a bearer [token].
AgentPost httpAgentPost(Uri api, String token, {String agent = 'agent'}) {
  final client = HttpClient();
  return (request) async {
    final call = await client.postUrl(api.resolve('/agent'));
    call.headers
      ..contentType = ContentType.json
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('x-mana-agent', agent);
    call.write(jsonEncode(request));
    final response = await call.close();
    final text = await response.transform(utf8.decoder).join();
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      body = text;
    }
    return (response.statusCode, body);
  };
}
