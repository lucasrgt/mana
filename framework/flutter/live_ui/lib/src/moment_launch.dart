import 'runtime_configuration.dart';
import 'configuration.dart';

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'timing.dart';

/// The knob scope the running Moment's recipe opened (`knobScope` in its
/// launch); `MomentActionTrace.attach` sends it with every API request.
abstract final class MomentKnobScope {
  static String? current;
}

/// Fetches only a disposable sandbox account from the authenticated local bridge.
/// Authentication is delegated to the app's normal session seam.
Future<String?> prepareMomentLaunch({
  required String apiUrl,
  Future<void> Function(Map<String, dynamic> launch)? onLaunch,
  Future<void> Function(String email, String password)? signIn,
  Future<void> Function(Map<String, dynamic> session)? restoreSession,
  http.Client? client,
}) async {
  if (!momentsBuild || !momentsEnabled || !momentBootstrapEnabled) {
    return null;
  }
  final endpoint = Uri.parse(MomentRuntime.bridgeUrl);
  bool local(Uri uri) => uri.scheme == 'http' && uri.host == '127.0.0.1';
  if (!local(endpoint) || !local(Uri.parse(apiUrl))) {
    throw StateError('Backend Moments requires loopback API and bridge');
  }
  final transport = client ?? http.Client();
  try {
    final response = await MomentTiming.measure(
      MomentStage.bootstrapRequest,
      () => transport
          .get(
            endpoint.resolve('/moments/bootstrap'),
            headers: {'Authorization': 'Bearer ${MomentRuntime.bridgeToken}'},
          )
          .timeout(const Duration(seconds: 8)),
    );
    if (response.statusCode != 200) {
      throw StateError('Moment bootstrap: ${response.statusCode}');
    }
    final launch = jsonDecode(response.body) as Map<String, dynamic>;
    if (launch['apiUrl'] != apiUrl) {
      throw StateError('Moment API does not match this app build');
    }
    final route = launch['route'] as String;
    MomentKnobScope.current = launch['knobScope'] as String?;
    if (!route.startsWith('/') || route.startsWith('//')) {
      throw StateError('Moment route must stay in the app');
    }
    if (onLaunch != null) {
      await onLaunch(launch);
    } else if (restoreSession != null) {
      await restoreSession(launch['session'] as Map<String, dynamic>);
    } else if (signIn != null) {
      final account = launch['account'] as Map<String, dynamic>;
      await signIn(account['email'] as String, account['password'] as String);
    } else {
      throw StateError('The app must restore the declared Moment session');
    }
    return route;
  } finally {
    if (client == null) transport.close();
  }
}
