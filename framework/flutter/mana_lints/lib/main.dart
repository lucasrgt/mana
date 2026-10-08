import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/design_system_only.dart';
import 'src/feature_boundaries.dart';
import 'src/library_independence.dart';
import 'src/use_primitives.dart';

final plugin = ManaLints();

/// Mana's rules for apps built on a shared design system. Each is a lint,
/// enabled per package under `plugins: mana_lints: diagnostics:`.
final class ManaLints extends Plugin {
  @override
  String get name => 'mana_lints';

  @override
  void register(PluginRegistry registry) {
    registry
      ..registerLintRule(DesignSystemOnly())
      ..registerLintRule(FeatureBoundaries())
      ..registerLintRule(LibraryIndependence())
      ..registerLintRule(UsePrimitives());
  }
}
