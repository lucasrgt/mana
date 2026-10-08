import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_ui.dart';

/// Runs an app as a long-lived Moments runtime under `flutter_tester`: the
/// Dart VM with Flutter's framework, no browser and no GPU. For every prepared
/// Moment the suite sends a restart; the app is unmounted, [reset] clears its
/// platform state (in-memory plugins), and [start] — the app's own Moment
/// bootstrap — returns the widget to mount, which then claims its bridge.
///
/// Evidence level: the widget runtime (layout, hit testing, gestures, the
/// app's HTTP and state), not a web renderer. The app's own fonts are loaded
/// so text lays out as in the app rather than in the test font.
void runHeadlessMoments({
  required int worker,
  required Future<Widget> Function() start,
  required void Function() reset,
  Size size = const Size(1280, 800),
}) {
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  // Moments dispatch pointers through GestureBinding as a device would.
  binding.shouldPropagateDevicePointerEvents = true;
  HttpOverrides.global = null;
  testWidgets('moments headless runtime', (tester) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    // The live binding lays out on its own surface (800×600 by default);
    // without this the app would read [size] from MediaQuery but get less.
    await binding.setSurfaceSize(size);
    final base = Uri.parse(Platform.environment['MOMENTS_CONTROL_URL']!);
    final control = base.resolve('/w/$worker');
    final client = HttpClient();
    var sequence = 0;
    try {
      await tester.runAsync(_loadAppFonts);
      MomentRuntime.configureHeadless(
        (await _request(client, base.resolve('/w/$worker/runtime')))!,
      );
      while (true) {
        final command = await _request(
          client,
          control.replace(queryParameters: {'after': '$sequence'}),
        );
        if (command == null) continue;
        if (command['operation'] == 'stop') break;
        sequence = command['sequence'] as int;
        await tester.pumpWidget(const SizedBox.shrink());
        reset();
        await tester.pumpWidget(await start());
        await _request(client, control, ack: sequence);
      }
    } finally {
      client.close(force: true);
    }
  }, timeout: Timeout.none);
}

Future<Map<String, dynamic>?> _request(
  HttpClient client,
  Uri uri, {
  int? ack,
}) async {
  final request = ack == null
      ? await client.getUrl(uri)
      : await client.postUrl(uri);
  if (ack != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode({'ack': ack}));
  }
  final response = await request.close();
  final body = await response.transform(utf8.decoder).join();
  if (response.statusCode == 204) return null;
  if (response.statusCode != 200) {
    throw StateError('Headless control ${response.statusCode}');
  }
  return jsonDecode(body) as Map<String, dynamic>;
}

Future<void> _loadAppFonts() async {
  final manifest = jsonDecode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<dynamic>;
  for (final family in manifest.cast<Map<String, dynamic>>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map<String, dynamic>>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}
