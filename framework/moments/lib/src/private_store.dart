import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState;

import 'errors.dart';
import 'http_server.dart';

/// Explicit development-only slots. Never included in projections or receipts.
final class PrivateStore {
  PrivateStore({required this.file, required this.keys}) {
    if (keys.isEmpty ||
        keys.toSet().length != keys.length ||
        keys.any((k) => !RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(k))) {
      throw const MomentsError('Invalid private store declaration');
    }
    final saved = File(file).existsSync()
        ? jsonDecode(File(file).readAsStringSync())
        : {'version': 1, 'values': <String, Object?>{}};
    final values = saved is Map ? saved['values'] : null;
    if (saved is! Map ||
        saved['version'] != 1 ||
        values is! Map ||
        values.entries.any((e) => !keys.contains(e.key) || e.value is! String || (e.value as String).length > 8192)) {
      throw const MomentsError('Invalid private actor state');
    }
    _values = values.cast();
  }

  final String file;
  final List<String> keys;
  late Map<String, String> _values;
  final _clients = <String, String>{};

  Future<bool> handle(HttpRequest request, Uri url, Body body) async {
    if (url.path != '/moments/private-store') return false;
    final response = request.response;
    if (request.method != 'POST') {
      reply(response, 405, {'error': 'POST required'});
      return true;
    }
    final input = await body();
    final client = input['client'];
    if (client is! String || !RegExp(r'^[a-f0-9-]{16,64}$').hasMatch(client))
      throw const MomentsError('Private store client required');
    final key = input['key'] ?? (input['operation'] == 'claim' && keys.length == 1 ? keys.single : null);
    if (key is! String || !keys.contains(key)) throw const MomentsError('Undeclared private store slot');
    if (input['operation'] == 'claim') {
      _clients[key] = client;
      reply(response, 200, {'claimed': true});
      return true;
    }
    if (_clients[key] != client) {
      reply(response, 409, {'error': 'Inactive private store client'});
      return true;
    }
    if (input['operation'] == 'read') {
      reply(response, 200, {'value': _values[input['key']]});
      return true;
    }
    final value = input['value'];
    if (input['operation'] != 'write' || value is! String || value.length > 8192)
      throw const MomentsError('Invalid private store write');
    final next = {..._values, key: value};
    savePrivateState(file, {'version': 1, 'values': next});
    _values = next;
    reply(response, 200, {'saved': true});
    return true;
  }
}
