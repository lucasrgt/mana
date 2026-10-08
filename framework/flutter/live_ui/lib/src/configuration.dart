import 'package:flutter/foundation.dart';

const momentsEnabled = bool.fromEnvironment('MANA_MOMENTS') || bool.fromEnvironment('MANA_LIVE_UI');
// The presentation editor must not start a polling connection merely because
// Moments is enabled; it needs its own explicit opt-in.
const liveUiEnabled = bool.fromEnvironment('MANA_LIVE_UI');
const momentBootstrapEnabled = bool.fromEnvironment('MANA_MOMENT_BOOTSTRAP');

/// Moments run in debug and profile builds (a profile artifact is the faster,
/// production-like runtime for suites); release builds never contain them.
const momentsBuild = !kReleaseMode;
