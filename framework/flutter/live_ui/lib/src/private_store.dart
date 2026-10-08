import 'runtime_configuration.dart';

import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'configuration.dart';

/// A private checkpoint slot owned by one disposable Moments actor.
/// Session validation still belongs to the app's normal authentication seam.
final class MomentPrivateStore {
  MomentPrivateStore._(this._endpoint, this._token, this.key, this._http)
    : _clientId = List.generate(
        24,
        (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();

  final Uri _endpoint;
  final String _token;
  final String key;
  final http.Client _http;
  final String _clientId;

  static Future<MomentPrivateStore> connect(String key) async {
    if (!momentsBuild || !momentsEnabled || !momentBootstrapEnabled) {
      throw StateError('Private Moment stores require a development launch');
    }
    final endpoint = Uri.parse(MomentRuntime.bridgeUrl);
    if (endpoint.scheme != 'http' || endpoint.host != '127.0.0.1') {
      throw StateError('Private Moment stores require a loopback bridge');
    }
    final store = MomentPrivateStore._(
      endpoint,
      MomentRuntime.bridgeToken,
      key,
      http.Client(),
    );
    try {
      await store._request('claim');
      return store;
    } catch (_) {
      store._http.close();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _request(
    String operation, [
    String? value,
  ]) async {
    final response = await _http
        .post(
          _endpoint.resolve('/moments/private-store'),
          headers: {
            'Authorization': 'Bearer $_token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({
            'operation': operation,
            'client': _clientId,
            'key': key,
            'value': ?value,
          }),
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      // Do not echo a response body that may contain private session material.
      throw StateError('Private Moment store: ${response.statusCode}');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<String?> read() async => (await _request('read'))['value'] as String?;
  Future<void> write(String value) async {
    await _request('write', value);
  }

  void close() => _http.close();
}
