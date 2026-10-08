import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'configuration.dart';

/// Debug-only endpoints for one actor/surface. No account/session data.
final class MomentRuntimeSettings {
  const MomentRuntimeSettings._(
    this.apiUrl,
    this.bridgeUrl,
    this.bridgeToken,
    this.surface,
  );
  final String apiUrl;
  final String bridgeUrl;
  final String bridgeToken;
  final String? surface;

  /// The Flutter launcher supplies this envelope only to an explicitly enabled
  /// native debug actor. It contains a local bridge capability, never a session.
  static MomentRuntimeSettings parseNativeRoute(String route) {
    try {
      if (route.length > 8192) throw const FormatException();
      final uri = Uri.parse(route);
      if (uri.hasScheme ||
          uri.hasAuthority ||
          uri.hasFragment ||
          uri.path != '/__mana_moments' ||
          uri.queryParametersAll.length != 1 ||
          uri.queryParametersAll['configuration']?.length != 1) {
        throw const FormatException();
      }
      final value = jsonDecode(uri.queryParameters['configuration']!);
      if (value is! Map<String, dynamic> ||
          value.length != 4 ||
          value['version'] != 1 ||
          value['bridgeUrl'] is! String) {
        throw const FormatException();
      }
      final origin = Uri.parse(value['bridgeUrl'] as String);
      return parse({...value, 'origin': origin.origin}, origin: origin);
    } on FormatException {
      // Do not echo the launch envelope or capability into diagnostics.
      throw StateError('Invalid native Moment launch configuration');
    }
  }

  static MomentRuntimeSettings parse(
    Object? input, {
    required Uri origin,
    String? surface,
  }) {
    bool localOrigin(Uri? uri) =>
        uri != null &&
        uri.scheme == 'http' &&
        uri.host == '127.0.0.1' &&
        uri.hasPort &&
        uri.port > 0 &&
        uri.port <= 65535 &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (uri.path.isEmpty || uri.path == '/');
    if (!localOrigin(origin) || input is! Map<String, dynamic>) {
      throw StateError(
        'Moment runtime requires a local origin and configuration',
      );
    }
    final api = input['apiUrl'];
    final bridge = input['bridgeUrl'];
    final token = input['bridgeToken'];
    final version = input['version'];
    final scoped = version == 2;
    if ((!scoped && version != 1) ||
        (scoped &&
            (surface == null ||
                !RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
                    .hasMatch(surface) ||
                input['surface'] != surface)) ||
        (!scoped && input.containsKey('surface')) ||
        input['origin'] != origin.origin ||
        api is! String ||
        bridge is! String ||
        token is! String ||
        !RegExp(r'^[a-f0-9]{48}$').hasMatch(token) ||
        !localOrigin(Uri.tryParse(api)) ||
        !localOrigin(Uri.tryParse(bridge))) {
      throw StateError('Invalid or foreign Moment runtime configuration');
    }
    return MomentRuntimeSettings._(api, bridge, token, scoped ? surface : null);
  }
}

/// Call once before creating API clients. Ordinary/profile/release builds retain
/// their compile-time configuration and never fetch this development endpoint.
abstract final class MomentRuntime {
  static const _dynamic =
      momentsBuild &&
      momentsEnabled &&
      bool.fromEnvironment('MANA_RUNTIME_BOOTSTRAP');
  static MomentRuntimeSettings? _settings;
  static Future<void>? _initializing;

  static Future<void> initialize() async {
    if (!_dynamic) return;
    if (!kIsWeb) {
      _settings ??= MomentRuntimeSettings.parseNativeRoute(
            WidgetsBinding.instance.platformDispatcher.defaultRouteName,
          );
      return;
    }
    return _initializing ??= _load();
  }

  /// A headless suite worker (see `headless.dart`) receives its runtime
  /// envelope from its supervisor instead of a route or a web origin.
  static void configureHeadless(Map<String, dynamic> input) {
    if (!_dynamic || kIsWeb) {
      throw StateError('Headless Moments require a runtime-bootstrap test build');
    }
    final origin = Uri.parse(input['bridgeUrl'] as String);
    _settings = MomentRuntimeSettings.parse(
      {...input, 'origin': origin.origin},
      origin: origin,
    );
  }

  static Future<void> _load() async {
    final origin = Uri.parse(Uri.base.origin);
    if (origin.scheme != 'http' || origin.host != '127.0.0.1') {
      throw StateError('Runtime Moment bootstrap requires a loopback origin');
    }
    final client = http.Client();
    try {
      final selectors = Uri.base.queryParametersAll['momentsActor'];
      if (selectors != null &&
          (selectors.length != 1 ||
              !RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$')
                  .hasMatch(selectors.single))) {
        throw StateError('Invalid Moment surface selector');
      }
      final surface = selectors?.single;
      final endpoint = origin
          .resolve('/__moments_runtime')
          .replace(
            queryParameters: surface == null ? null : {'momentsActor': surface},
          );
      final response = await client
          .get(endpoint)
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200 || response.bodyBytes.length > 8192) {
        throw StateError('Moment runtime configuration unavailable');
      }
      _settings = MomentRuntimeSettings.parse(
        jsonDecode(response.body),
        origin: origin,
        surface: surface,
      );
    } on FormatException {
      throw StateError('Invalid Moment runtime configuration');
    } finally {
      client.close();
    }
  }

  static MomentRuntimeSettings? get _current {
    if (_dynamic && _settings == null) {
      throw StateError('Initialize MomentRuntime before starting this actor');
    }
    return _settings;
  }

  static String apiUrl(String declared) => _current?.apiUrl ?? declared;

  /// Routers must use the restored Moment route, not the private launch envelope.
  static bool get nativeBootstrap => _dynamic && !kIsWeb;

  /// Non-null only for a selected interface in the local multi-surface host.
  static String? get surface => _current?.surface;
  static String get bridgeUrl =>
      _current?.bridgeUrl ?? const String.fromEnvironment('LIVE_UI_URL');
  static String get bridgeToken =>
      _current?.bridgeToken ?? const String.fromEnvironment('LIVE_UI_TOKEN');
}
