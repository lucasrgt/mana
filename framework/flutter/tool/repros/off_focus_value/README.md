# Unfocused values in web accessibility

A minimal reproduction independent of Mana, Ash, Moments, the generated form, HTTP and
the `enabled` state. It uses only the Flutter SDK and Material.

```sh
cd framework/flutter/tool/repros/off_focus_value
flutter pub get
flutter analyze
flutter build web --release --no-wasm-dry-run
python -m http.server 5246 --bind 127.0.0.1 --directory build/web
```

Open `http://127.0.0.1:5246/`. The app enables Semantics explicitly. Watch both inputs'
values in the accessibility tree or the DOM `input.value` property, comparing them with
the controllers' text shown on the page. `outerHTML` alone is not enough: it does not
necessarily include that property.

1. Without focusing the fields, check the initial values.
2. Focus the first field and then the second.
3. Click **Clear both** and check the values without giving focus back to the fields.
4. Click **Replace both** and check again.
5. Focus only the first field and check both again.

## Local result

Flutter 3.47.2, framework `d3b14c876900e553bc736ca19295fc09e3853e8e`, engine
`a804b261645ef8c13eb3d5c44a5c2fb0340c5539`, Dart 3.13.2, web release in Chromium. Dart
analysis and the build passed. The SDK was not changed.

| Step | Controllers/visual | DOM/accessibility input values |
| --- | --- | --- |
| Initial, unfocused | Initial first / Initial second | Both empty |
| After focusing both and clearing | Both empty | Initial first / Initial second |
| Replacement without focus | Replaced first / Replaced second | Initial first / Initial second |
| Focus on the first only | Replaced first / Replaced second | Replaced first / Initial second |

The divergence persisted across actions; it is not just an observation before the
frame.

In that SDK, `SemanticTextField.update()` updates focus, dimensions, label, hint and
type, but does not copy the unfocused value into the input. The active editing strategy
syncs the field when it gets focus. The relevant file is
`engine/src/flutter/lib/web_ui/lib/src/engine/semantics/text_field.dart`. There is a
[related upstream issue, #147200](https://github.com/flutter/flutter/issues/147200),
about a test that did not detect the missing `input.value`; it is not claimed to cover
this whole reproduction.

Mana ships no DOM workaround, focus stealing, automatic remounting or SDK fork. Screen
reader, other-browser and mobile audits are still pending. This reproduction exists to
evaluate a future Flutter fix/version and to avoid blaming the form generator.

## Isolated candidate fix

`build_candidate.py` repeats an engine experiment on Linux x86_64:

```sh
# From the repository root, with a new output folder:
python framework/flutter/tool/repros/off_focus_value/build_candidate.py \
  --flutter-sdk "$HOME/.local/share/flutter" \
  --output "$PWD/.proofs/accessibility/candidate-new"
```

The script checks the exact hash of the reviewed source, copies the web SDK, applies
eight lines to `SemanticTextField.update()`, recompiles `dart2js_platform.dill` and
produces two releases through the official `--local-web-sdk` flag. Unfocused values are
copied by `EditingState.applyTextToDomElement`; it does not change selection, does not
take focus and leaves the active field on the editing strategy. The patch and logs stay
in the disposable output. The installed SDK is not modified; the script compares all its
web files before/after. It is not a build dependency of Mana.

Serve `candidate-new/web` and `candidate-new/variants` on separate ports with
`python -m http.server ... --bind 127.0.0.1 --directory ...`. The build writes
`build.json` with status **built-not-browser-verified**: it does not certify the UI. An
existing directory or a different engine source stops the experiment.

In a real browser, the candidate synced initial, cleared and replaced unfocused values
in the DOM/accessibility tree; typing, mid-sentence insertion and Tab were kept;
multiline fields accepted Enter; disabled and read-only fields kept their behaviour; an
obscured field stayed masked. Compiled with the candidate engine, a Mana generated form
also cleared both fields in the visuals and in `input.value` after a real creation
against Ash/Postgres, with exactly one record created.

**Experimental fix, not adopted by Mana.** Screen reader, IME composition, other
browsers/platforms and upstream review are still missing. The defect remains in app
releases built with the original SDK.
