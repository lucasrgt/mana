# Mana local Dart tools

The import parser uses `analyzer` 14.4.0 and the resolution pinned in `pubspec.lock`.
It reads ASTs; it never runs the app's code. Conditional imports come in with all their
alternatives, as do exports, parts and `part of` URIs.

Prepare once, from the checkout root:

```sh
dart pub get --directory framework/flutter/devtools --enforce-lockfile
framework/moments/moments tools
```

The second command compiles a private native executable into `.dart_tool/`. Its identity
includes source, manifests, resolution, SDK version and ABI; the binary's checksum is
verified before use. A change in any of those requires a rebuild. `moments affected`
installs nothing, does not compile the tool and does not touch the network. Without the
current tool, the selection widens to the whole catalog with `dart-impact-unavailable`;
it never returns an empty selection because the parser is missing.

On one app, processing 77 files took about 79 ms with the executable; running
the parser directly through the JIT took about 4.9 s, which is why the planning command
never does that. These are single local measurements.
