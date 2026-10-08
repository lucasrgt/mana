import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

/// Holds presentation overrides only. Never receives form values or credentials.
final class LiveUiController extends ChangeNotifier {
  LiveUiController({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;
  final String session = DateTime.now().microsecondsSinceEpoch.toString();
  Map<String, String> _values = const {};
  String _revision = '';
  bool _disposed = false;
  bool _started = false;
  String? lastError;

  String? value(String key) => _values[key];
  String get revision => _revision;

  T? token<T extends Enum>(String key, List<T> candidates) {
    final name = value(key);
    for (final candidate in candidates) {
      if (candidate.name == name) return candidate;
    }
    return null;
  }

  /// A whole revision is applied together; existing widget state stays mounted.
  void apply(String revision, Map<String, String> values) {
    if (_disposed || revision == _revision) return;
    _values = Map.unmodifiable(values);
    _revision = revision;
    lastError = null;
    notifyListeners();
  }

  /// Long polling wakes on a patch immediately; there is no polling interval.
  Future<void> connect(Uri endpoint, String token) async {
    if (!kDebugMode || _started || _disposed) return;
    _started = true;
    if (endpoint.scheme != 'http' ||
        !const ['127.0.0.1', 'localhost', '::1'].contains(endpoint.host)) {
      lastError = 'Live UI requires a loopback HTTP endpoint.';
      return;
    }
    final headers = {'Authorization': 'Bearer $token'};
    while (!_disposed) {
      try {
        final response = await _client.get(
          endpoint
              .resolve('/changes')
              .replace(
                queryParameters: {'since': _revision, 'session': session},
              ),
          headers: headers,
        );
        if (_disposed) return;
        if (response.statusCode == 204) continue;
        if (response.statusCode != 200) {
          throw StateError('Bridge returned ${response.statusCode}');
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final next = data['revision'] as String;
        final values = Map<String, String>.from(data['values'] as Map);
        final watch = Stopwatch()..start();
        apply(next, values);
        // This is a Flutter frame boundary, not proof of display scanout.
        await SchedulerBinding.instance.endOfFrame;
        if (_disposed) return;
        final ack = await _client.post(
          endpoint.resolve('/ack'),
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'revision': next,
            'session': session,
            'applyToFrameMs': watch.elapsedMicroseconds / 1000,
          }),
        );
        if (ack.statusCode != 200) {
          throw StateError('Bridge rejected frame acknowledgment');
        }
      } on Object catch (error) {
        if (_disposed) return;
        lastError = error.toString();
        debugPrint('Live UI: $lastError (retrying)');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _client.close();
    super.dispose();
  }
}
