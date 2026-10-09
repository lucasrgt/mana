import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'configuration.dart';
import 'moment_launch.dart' show MomentKnobScope;

/// Positive observations from gesture-originated HTTP requests, not coverage.
/// Detached jobs and requests scheduled outside this zone are not attributed.
final class MomentActionTrace {
  static const enabled = momentsBuild;
  MomentActionTrace._(this.gesture, this._emit);
  final String gesture;
  final Future<void> Function(Map<String, dynamic>) _emit;
  static final Object _key = Object();
  static MomentActionTrace? get current =>
      momentsBuild ? Zone.current[_key] as MomentActionTrace? : null;

  static Future<T> run<T>(
    String gesture,
    Future<void> Function(Map<String, dynamic>) emit,
    Future<T> Function() action,
  ) => runZoned(action, zoneValues: {_key: MomentActionTrace._(gesture, emit)});

  /// Never attach development metadata to a different origin or a release API.
  static bool allows(Uri request, Uri api, {bool backendEnabled = false}) =>
      momentsBuild &&
      backendEnabled &&
      api.scheme == 'http' &&
      const ['127.0.0.1', 'localhost', '::1'].contains(api.host) &&
      request.origin == api.origin &&
      request.userInfo.isEmpty;

  /// Sends every request with the Moment's `x-mana-knob-scope`, and each one
  /// made inside a gesture with `x-mana-gesture`, recording the backend's
  /// `x-mana-actions` receipt — only to [api] on
  /// loopback, and only in builds defined with `MANA_ACTION_TRACE=true`
  /// (Moments sets it for its own runs). One line per app:
  /// `MomentActionTrace.attach(dio, Uri.parse(baseUrl))`.
  static void attach(Dio dio, Uri api) {
    if (!enabled) return;
    const backendEnabled = bool.fromEnvironment('MANA_ACTION_TRACE');
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final scope = MomentKnobScope.current;
          if (scope != null &&
              allows(options.uri, api, backendEnabled: backendEnabled)) {
            options.headers['x-mana-knob-scope'] = scope;
          }
          final trace = current;
          if (trace != null &&
              allows(options.uri, api, backendEnabled: backendEnabled)) {
            options.headers['x-mana-gesture'] = trace.gesture;
            options.extra['mana.actionTrace'] = trace;
          }
          handler.next(options);
        },
        onResponse: (response, handler) async {
          final trace =
              response.requestOptions.extra['mana.actionTrace']
                  as MomentActionTrace?;
          await trace?.record(response.headers['x-mana-actions']?.join(','));
          handler.next(response);
        },
        onError: (error, handler) async {
          final trace =
              error.requestOptions.extra['mana.actionTrace']
                  as MomentActionTrace?;
          await trace?.record(
            error.response?.headers['x-mana-actions']?.join(','),
          );
          handler.next(error);
        },
      ),
    );
  }

  Future<void> record(String? header) async {
    if (!momentsBuild || header == null || header.length > 7000) return;
    try {
      final value = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(header))),
      );
      if (value is! Map<String, dynamic> ||
          value['gesture'] != gesture ||
          !const [1, 2, 3].contains(value['version']) ||
          value['scope'] != 'request-actions-only' ||
          value['coverage'] != 'not-established') {
        return;
      }
      await _emit(value).timeout(const Duration(seconds: 2));
    } on Object {
      // Observability must not turn an accepted business response into failure.
      // Missing receipts remain missing evidence, never proof of no actions.
    }
  }
}
