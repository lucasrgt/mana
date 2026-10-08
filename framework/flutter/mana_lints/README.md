# mana_lints

Analyzer plugin for Flutter apps built on a shared design system. Three lints,
each enabled per package in `analysis_options.yaml`:

```yaml
plugins:
  mana_lints:
    path: ../../framework/flutter/mana_lints
    diagnostics:
      mana_design_system_only: true   # apps
      mana_feature_boundaries: true   # apps
      mana_library_independence: true # shared libraries
```

- `mana_design_system_only`: screens compose the design system. No raw
  Material/Cupertino control (`ElevatedButton`, `TextField`, `showDialog`…),
  no `Color(…)`/`Colors.*`, no literal `EdgeInsets`/`SizedBox` sizes.
- `mana_feature_boundaries`: a file in `lib/features/<area>/<feature>/` imports
  its own feature, what sits directly in `lib/features/<area>/`, and anything
  outside `lib/features`, never another feature's files.
- `mana_library_independence`: a package without `lib/main.dart` never imports
  one that has it; what apps share flows down to them.

Diagnostics show in the editor and in `dart analyze` run at the package root;
`flutter analyze` does not surface analyzer plugins. A deliberate exception is
`// ignore: mana_lints/<rule>` with the reason beside it.
