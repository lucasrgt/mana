import 'package:flutter/foundation.dart';

const momentsEnabled = bool.fromEnvironment('MANA_MOMENTS');
const momentBootstrapEnabled = bool.fromEnvironment('MANA_MOMENT_BOOTSTRAP');

/// Moments run in debug and profile builds (a profile artifact is the faster,
/// production-like runtime for suites); release builds never contain them.
const momentsBuild = !kReleaseMode;
