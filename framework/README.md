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
| [`benchmark/`](benchmark/README.md) | real Host Point tasks done by an agent with and without Moments: the harness, the tasks and the raw results |
| **Elixir** (`ash/`) | |
| [`ash/core`](ash/core/README.md) | Spark extensions: privacy, retention, limits, errors, enums, search, uploads, storage, webhooks, verbs, views, history, exploration, snapshots, the program graph, replay and undo |
| [`ash/moments`](ash/moments/README.md) | the `moment` DSL and backend recipes |
| [`ash/session`](ash/session/README.md) | short sessions and rotating refresh for Flutter clients |
| [`ash/runtime`](ash/runtime/README.md) | release configuration, edge, metrics and readiness |
| `ash/br` | Brazilian validations (CPF, CNPJ, license plate) |
| [`ash/lint`](ash/lint/README.md) | `mana_lint`: Credo checks for Ash and Mana idioms (effects in transaction hooks, N+1, swallowing rescues, reimplemented primitives, …) |
| [`ash/upgrade`](ash/upgrade/README.md) | `mana_upgrade`: Sourceror codemods to newer Mana idioms, behind `mana upgrade` |
| **Flutter** (`flutter/`) | |
| [`flutter/ash_session`](flutter/ash_session/README.md) | session, recovery and Bearer over the generated client |
| `flutter/mana_command` | stateful commands (`Query`, `RowAction`, `QuietAfterDispose`) and verb gates |
| `flutter/mana_live` | live entities over Phoenix channels |
| `flutter/mana_primitives` | Dart types for the Mana primitives |
| [`flutter/live_ui`](flutter/live_ui/README.md) | the app's bridge to Moments (resume and inspection) |
| [`flutter/mana_storage`](flutter/mana_storage/README.md) | secure storage with explicit failures |
| [`flutter/mana_lints`](flutter/mana_lints/README.md) | lints for the shared design system |
| [`flutter/devtools`](flutter/devtools/README.md) | local Dart tools (import graph) |

## Requirements

git, Docker (running) and the Flutter SDK, on Linux or macOS. Elixir runs in the
pinned image of [`ash/toolchain`](ash/toolchain/Dockerfile) (or the machine's own with
`MANA_ELIXIR=local`); the contract tools and the Java runtime of the client generator
are pinned in [`contracts/toolchain.json`](contracts/toolchain.json) and fetched by
`cli/mana contracts install`. `cli/mana doctor` names what is missing. CI's
`first-green` job times `mana new` to a green headless suite on a clean Linux runner,
with a 300-second budget.

## Benchmark

Does an agent do better with Moments? [`benchmark/`](benchmark/README.md)
measures it on Host Point: twelve real tasks (bug fixes, rule changes,
features and UI changes, each pinned to the commit that made it), each done
by the same agent, model and budget with Moments and without them, scored by
the tests the real change came with, which the agent never sees, and by the
project's other tests (bugs that reach the pull request). `mana eval
benchmark` runs it unattended; `mana eval benchmark report` recomputes the
tables from the published raw results.

**Results: pending the first run.** Success rate, wall time, tokens and
held-out failures per condition will be quoted here from
[`benchmark/results/`](benchmark/results/README.md) once a run is published.

## Documentation

- Every piece's current contract is its own README.
- The Moments protocol: [`moments/protocol-v0.1.md`](moments/protocol-v0.1.md)
  (the runner checks the file's hash, which is why it lives next to the code).
