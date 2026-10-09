import 'package:flutter/foundation.dart';

import 'configuration.dart';

/// Leaving the app for something it does not draw: a payment page, a chat
/// app, the browser, the phone's maps. In a running Moment nothing leaves:
/// [open] records [label] in [opened] instead, so a journey checks that the
/// app handed off, and where, without another app taking the screen. The
/// app reports [opened] in its projection (`handOff`).
abstract final class MomentHandOff {
  /// The label of the last hand-off a Moment recorded; `none` before any.
  static final opened = ValueNotifier<String>('none');

  static bool _recording = false;

  /// Whether hand-offs are recorded instead of performed: set once a Moment
  /// launched this build (`prepareMomentLaunch`).
  static bool get recording => momentsBuild && _recording;

  static void startRecording() => _recording = momentsBuild;

  /// Hands off with [launch], or, in a Moment, records [label] (`whatsapp`,
  /// `stripe-checkout`, `browser`).
  static Future<void> open(String label, Future<void> Function() launch) async {
    if (recording) {
      opened.value = label;
      return;
    }
    await launch();
  }
}
