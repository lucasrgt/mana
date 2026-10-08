# Mana

An Ash/Elixir + Flutter framework. The product declares its intent once, in Ash
resources; Mana derives from it the API contract, the Dart client, privacy,
limits and the Moments that prove each journey. The contract for agents is in
[AGENTS.md](AGENTS.md).

## Pieces

| Folder | What it is |
| --- | --- |
| [`cli/`](cli/README.md) | `mana new` (a whole project to start from), `setup`, `doctor`, `lab` and `agent`, driven by the project's `mana.toml` |
| [`moments/`](moments/README.md) | the Moments runner: open, sync and run named situations in a browser, `flutter_tester` or Android |
| [`contracts/`](contracts/README.md) | Ash → OpenAPI → Dart client, with `oasdiff` blocking breaking changes |
| **Elixir** (`ash/`) | |
| [`ash/core`](ash/core/README.md) | Spark extensions: privacy, retention, limits, errors, enums, search, uploads, storage, webhooks, verbs, views, history and more |
| [`ash/moments`](ash/moments/README.md) | the `moment` DSL and backend recipes |
| [`ash/session`](ash/session/README.md) | short sessions and rotating refresh for Flutter clients |
| [`ash/runtime`](ash/runtime/README.md) | release configuration, edge, metrics and readiness |
| [`ash/presentation`](ash/presentation/README.md) | forms declared in Elixir, compiled to Flutter |
| `ash/br` | Brazilian validations (CPF, CNPJ, license plate) |
| **Flutter** (`flutter/`) | |
| [`flutter/ash_session`](flutter/ash_session/README.md) | session, recovery and Bearer over the generated client |
| [`flutter/ash_query`](flutter/ash_query/README.md) | Ash read pages (`OffsetPage`) |
| `flutter/mana_command` | stateful commands (`Query`, `RowAction`, `QuietAfterDispose`) and verb gates |
| `flutter/mana_live` | live entities over Phoenix channels |
| `flutter/mana_primitives` | Dart types for the Mana primitives |
| [`flutter/live_ui`](flutter/live_ui/README.md) | the app's bridge to Moments (resume and inspection) |
| [`flutter/mana_storage`](flutter/mana_storage/README.md) | secure storage with explicit failures |
| [`flutter/mana_lints`](flutter/mana_lints/README.md) | lints for the shared design system |
| [`flutter/devtools`](flutter/devtools/README.md) | local Dart tools (import graph) |

## Documentation

- Every piece's current contract is its own README.
- The Moments protocol: [`moments/protocol-v0.1.md`](moments/protocol-v0.1.md)
  (the runner checks the file's hash, which is why it lives next to the code).
