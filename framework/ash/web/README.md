# Mana Web

The LiveView adapter of Mana: each Mana capability on a Phoenix LiveView screen. A LiveView
calls Ash directly, so this package reads the same declarations the Flutter adapter receives
through the JSON:API contract (`contracts`), with nothing generated in between.

| Capability | Here |
|---|---|
| Verbs | `ManaWeb.Verbs.gate/1` shows a control only when the record offers its verb; `describe/2` says its risk and whether to confirm; `run/4` runs it and records its feature |
| Errors | `ManaWeb.Verbs.refusal/1`: the declared code, message and field of a refusal |
| Moments | `ManaWeb.Moments` runs a Moment on LiveView screens, headless, from the same manifest the Dart runner reads; `ManaWeb.Moments.Case` makes every web Moment an ExUnit test |

## Moments on LiveView

```elixir
defmodule MyAppWeb.MomentsTest do
  use MyAppWeb.ConnCase, async: false

  use ManaWeb.Moments.Case,
    domain: MyApp.Agencies,
    endpoint: MyAppWeb.Endpoint,
    recipes: MyApp.Moments.Agencies.__recipes__(),
    sign_in: &__MODULE__.sign_in/2

  def sign_in(conn, account), do: ...
end
```

The recipe prepares the situation with the app's actions, `sign_in` puts the launch's
account in the conn, the screen mounts at the launch's `route`, the steps run in order and
the criteria are judged after each step and at the end. A screen reports what the runner
reads: `ManaWeb.Verbs.gate` marks each offered verb (`data-mana-verb="type.verb:<id>"`),
`data-moment-field` and `data-moment-value` report a declared UI field, and
`data-moment-key` names what a `tap:` step clicks.

`tap` and `verb` steps run, and so do `offered`, `not_offered`, `ui_equals` and
`backend_equals`. `fill`, `submit`, `reveal`, `swipe`, `long_press`, `back` and
`restored` are unavailable on LiveView for now, which leaves the verdict inconclusive:
unavailable evidence is never green. The AVP verdict is the Dart runner's, and both are
tested against `framework/contracts/moments/avp-verdicts.json`.

Which capabilities exist here, and which are planned or do not apply to a LiveView, is the
`adapters.live` column of `framework/catalog.toml`. `ManaWeb.implements/0` lists what is
implemented, and `test/catalog_test.exs` fails when the two disagree, so the Flutter and
LiveView adapters cannot drift without the catalog saying so.
