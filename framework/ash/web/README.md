# Mana Web

The LiveView adapter of Mana: each Mana capability on a Phoenix LiveView screen. A LiveView
calls Ash directly, so this package reads the same declarations the Flutter adapter receives
through the JSON:API contract (`contracts`), with nothing generated in between.

| Capability | Here |
|---|---|
| Verbs | `ManaWeb.Verbs.gate/1` shows a control only when the record offers its verb; `describe/2` says its risk and whether to confirm; `run/4` runs it and records its feature |
| Errors | `ManaWeb.Verbs.refusal/1`: the declared code, message and field of a refusal |

Which capabilities exist here, and which are planned or do not apply to a LiveView, is the
`adapters.live` column of `framework/catalog.toml`. `ManaWeb.implements/0` lists what is
implemented, and `test/catalog_test.exs` fails when the two disagree, so the Flutter and
LiveView adapters cannot drift without the catalog saying so.
