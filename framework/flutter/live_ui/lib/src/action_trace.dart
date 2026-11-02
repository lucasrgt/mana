import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'configuration.dart';
import 'moment_launch.dart' show MomentDataScope, MomentKnobScope;

/// The app's requests in flight through [MomentActionTrace.attach]: while
/// one is out, a journey's step is waiting on the backend, not stuck, so its
/// postcondition wait goes on (`MomentController` reports it). Never a
/// criterion.
final class MomentActivity {
  MomentActivity._();
  static var _inFlight = 0;
  static final _listeners = <void Function()>[];

  static int get inFlight => _inFlight;

  static void addListener(void Function() listener) => _listeners.add(listener);
  static void removeListener(void Function() listener) =>
      _listeners.remove(listener);

  static void _change(int delta) {
    _inFlight += delta;
    for (final listener in [..._listeners]) {
      listener();
    }
  }
}

/// Positive observations from gesture-originated HTTP requests, not coverage.
/// Detached jobs and requests scheduled outside this zone are not attributed.
final class MomentActionTrace {
  static const enabled = momentsBuild;
  MomentActionTrace._(this.gesture, this._emit, this.verb);
  final String gesture;
  final Future<void> Function(Map<String, dynamic>) _emit;

  /// The verb the gesture performs (`booking.pay:<id>`): its target's, when
  /// it aimed at a verb key, or the one a control named as it ran
  /// (`MomentAffordances.performing`). Its receipts carry it as `verb`.
  String? verb;
  static final Object _key = Object();
  static MomentActionTrace? get current =>
      momentsBuild ? Zone.current[_key] as MomentActionTrace? : null;

  static Future<T> run<T>(
    String gesture,
    Future<void> Function(Map<String, dynamic>) emit,
    Future<T> Function() action, {
    String? verb,
  }) => runZoned(
    action,
    zoneValues: {_key: MomentActionTrace._(gesture, emit, verb)},
  );

  /// Never attach development metadata to a different origin or a release API.
  static bool allows(Uri request, Uri api, {bool backendEnabled = false}) =>
      momentsBuild &&
      backendEnabled &&
      api.scheme == 'http' &&
      const ['127.0.0.1', 'localhost', '::1'].contains(api.host) &&
      request.origin == api.origin &&
      request.userInfo.isEmpty;

  /// Sends every request with the Moment's `x-mana-knob-scope` and
  /// `x-mana-data-scope`, and each one
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
          options.extra['mana.activity'] = true;
          MomentActivity._change(1);
          final scope = MomentKnobScope.current;
          if (scope != null &&
              allows(options.uri, api, backendEnabled: backendEnabled)) {
            options.headers['x-mana-knob-scope'] = scope;
          }
          final data = MomentDataScope.current;
          if (data != null &&
              allows(options.uri, api, backendEnabled: backendEnabled)) {
            options.headers['x-mana-data-scope'] = data;
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
          _settled(response.requestOptions);
          final trace =
              response.requestOptions.extra['mana.actionTrace']
                  as MomentActionTrace?;
          await trace?.record(response.headers['x-mana-actions']?.join(','));
          handler.next(response);
        },
        onError: (error, handler) async {
          _settled(error.requestOptions);
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

  static void _settled(RequestOptions options) {
    if (options.extra.remove('mana.activity') == true) {
      MomentActivity._change(-1);
    }
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
      final named = verb;
      await _emit(named == null ? value : {...value, 'verb': named})
          .timeout(const Duration(seconds: 2));
    } on Object {
      // Observability must not turn an accepted business response into failure.
      // Missing receipts remain missing evidence, never proof of no actions.
    }
  }
}
