# PRD — Mana 9+

Status: delivered, except the first benchmark run (#31) · Owner: Mana · Baseline: an outside review scored Mana 7/10
(idea ≈ 8.5, execution ≈ 6.5). This PRD lists every point that review raised,
checked against the code, plus what this round of work found, so execution
catches up with the idea.

Already done in this round (for context, not repeated below): notices are
delivered by an Ash notifier after the outermost commit; a checkpoint's dry run
drops its notifications with its rollback; every Elixir package formats with
`mix format` and passes Credo strict with nothing switched off; `mana doctor`
holds projects to both.

## P0 — promises that can break today

### 1. Live updates announce before the commit
`Mana.Entity.Changed` (core/lib/mana/entity.ex, `change/3`) calls
`Mana.Entity.announce/1` in an `after_action`, inside the transaction. A client
told "changed" can read the record before the write commits, or after it rolled
back.

- Fix: announce from an Ash notifier, like `Mana.Notifications.Notifier`
  (sent after the outermost commit, dropped on rollback). Scheduling deadlines
  stays in the transaction: an Oban job row written with the change is the
  atomic, idiomatic way.
- Accept: a Postgres test where an action nested in a transaction that rolls
  back broadcasts nothing, and one that commits broadcasts once, after commit.

### 2. A deadline can expire a record that just moved on
`Mana.Entity.run_deadline/3` reads the record, checks `when`, then `Ash.update!`
without a lock. A payment landing between the check and the update is expired
anyway.

- Fix: the deadline's update re-asks `when` on the stored row under the same
  per-record lock `one_at_a_time` takes (the pattern `Mana.Verbs.Recheck`
  already uses), and does nothing when it no longer holds.
- Accept: a Postgres test that races `pay` against the deadline 50 times never
  ends with a paid record expired.

### 3. A history write that fails takes the action down
`Mana.History.Record` writes the entry inside the action's transaction; on
Postgres an insert error aborts the whole transaction, while the docs say a
failed entry is reported, not fatal.

- Decide and make code and docs agree. Recommended: the entry is atomic with
  the change (a change without its entry is worse than a refused change), the
  error reporter still gets the failure, and the docs say so. The alternative
  (best effort) needs a savepoint around the insert.
- Accept: a Postgres test for the chosen behaviour.

### 4. Erasure leaves personal data in history
`Mana.Privacy.erase/2` clears the actor of the subject's entries (`forget`),
but entries about records that stay (a booking that outlives the traveler)
keep the subject's personal values in `before`/`after`/`params`.

- Fix: on erase, scrub from those entries every field the resources declare as
  personal (privacy `export`, history `redact`), replacing values with
  `"[erased]"`.
- Accept: a test that erases a traveler and finds none of their exported field
  values in any remaining entry.

## P1 — what proves the promises

### 5. A Postgres test harness for mana_core
The ~140 Elixir tests run on ETS, so advisory locks, `Recheck`, nested
transactions and the notifier timing never run in a test.

- Fix: a test support layer with AshPostgres resources (`MANA_TEST_POSTGRES`, as
  the snapshot tests already do) and tests for: concurrent verbs (one lands),
  `Recheck` under contention, P0 items 1–4, notices after commit/never on
  rollback, `Mana.Explore` on Postgres through `snapshot_reset`.

### 6. CI
There is no CI configuration in the repository.

- Fix: GitHub Actions running, per package: `mix format --check-formatted`,
  `mix credo --strict`, `mix compile --warnings-as-errors`, `mix test` (with a
  Postgres service); `dart analyze` / `dart test` for cli and moments;
  `flutter analyze` / `flutter test` for every Flutter package;
  `mana capabilities skill --check`.

### 7. Tests for the untested core
`moments/lib/src/sandbox.dart` and `suite.dart` (the heart of `up` and
`suite`), `ash/session` and `ash/contracts` have no tests.

- Fix: unit tests for their pure parts (state machines, argument and identity
  handling, contract normalization) and one end-to-end suite run in CI against
  the `mana new` starter.

### 8. Long journeys miss their postcondition under parallel load
In Host Point's hosts suite, one long creation journey (a different one each
run) sometimes misses its 8 s postcondition with 4 workers, and passes alone.

- Fix: find where the time goes (rebuild, network, backend under the shared
  load) and make waiting depend on progress (the app reporting idle) rather
  than a fixed budget; record per-step timings in the receipt.
- Accept: 10 consecutive full hosts suites pass.

## P2 — shortcuts to replace

### 9. Notice grouping owns its table with spawn + sleep
`Mana.Notifications` creates its ETS table from a `spawn`ed process found by
`Process.register` and waits with `Process.sleep(5)` in a retry loop.

- Fix: a supervised owner (`Mana.Notifications.Groups`, a child the app adds
  like `Mana.Feature`), created at boot, sweeping on a timer.

### 10. Knobs rewrite :persistent_term in the read path
`Mana.Knobs` refreshes its cache with `:persistent_term.put/2` every
`knob_ttl_ms` (5 s) from the read path; every put triggers a global GC scan.

- Fix: an ETS cache (`read_concurrency: true`) owned by a supervised process;
  `:persistent_term` only for values that change at deploy time.

### 11. The generated client is patched with regular expressions
`cli/lib/src/client.dart` rewrites the OpenAPI Generator's Dart output with
`RegExp` replacements.

- Fix: move each patch to the generator (templates or config) or to an
  AST-based rewrite with `package:analyzer`; test every patch against a fixture.

### 12. Shutdown can hang on a grandchild holding the pipe
A process started by the runner whose own child keeps stdout open blocks the
runner's shutdown.

- Fix: start children in their own process group, stop the group, and stop
  waiting on the pipe after the process exits.

## P3 — reach

### 13. Moments do what their protocol says
`moments/lib/src/protocol.dart` declares `independentFork`,
`wholeSituationSnapshot`, `normalizedVersionComparison`,
`saveExplorationAsMoment` and `traceFromRoot` false.

- Fix, now that `Mana.Snapshot` and `Mana.History` exist: `fork` and `diff`
  over data scopes, `trace` from the root through history, `save` from an
  exploration trace (`Mana.Explore.save/2`); flip each flag with its
  conformance test.

### 14. macOS (and iOS)
The runner relies on `/proc`, `flock` and user systemd: Linux only.

- Fix: a platform layer for process identity, locking and services; macOS in CI;
  the iOS simulator as a native transport.

### 15. Moments next to the feature they prove
Moments are declared per app (`moments/<app>.ex`, hundreds of lines), away from
the resources they prove. The DSL already lives on Ash domains: allow a
feature's domain to declare its Moments for several apps.

### 16. Codemods for upgrades
Migrating apps (tap keys to `verb:` steps, hand-written windows to `within:`)
is manual. A `mana upgrade` built on Sourceror/Igniter rewrites code with
comments preserved.

### 17. mana_lint
A Credo plugin (`framework/ash/lint`, app `:mana_lint`) with checks for what
Mana and Ash expect and Credo does not know. Every check is AST-based and
configurable in `.credo.exs` (effect functions, allowed paths) instead of
suppressed in code; `mana doctor` requires the plugin and the template ships it.

| Check | Flags |
|---|---|
| `AshEffectInTransactionHook` | an effect (configurable: payment adapters, storage put/delete, mailers, HTTP clients, push, PubSub/Endpoint broadcasts, `Mana.Entity.announce`) in a fn given to `before_action`/`after_action`/`around_action` or in a `change/3` body; a broadcast or notice in `after_transaction`. Not `before_transaction`, `Oban.insert`, notifiers |
| `AshSeedOutsideSeeds` | `Ash.Seed.*` outside tests, seeds, Moments recipes and support code |
| `DirectRepoOnResource` | `Repo.*`/`Ecto.Adapters.SQL.query*` on a table a resource declares (advisory locks and probes allowed) |
| `RawSqlInCalculation` | `Repo.query*` or per-record `Ash.get/read*` inside a calculation |
| `AshCallInLoop` | an Ash read/write inside `Enum.*`/`Stream.*`/`for` over records that came from an Ash read |
| `ManualActorAuthorization` | a read with `authorize?: false` compared against `actor.id` in an action, change or validation |
| `ValidationAsChange` | `add_error` in `change/3` on a pure attribute/argument condition |
| `GetOrCreate` | read-then-create on one resource instead of `upsert?` |
| `AggregateInElixir` | a read summed, counted or maxed in Elixir instead of an aggregate |
| `InMemoryFilterAfterRead` | a read filtered in Elixir on a plain field comparison |
| `UnsupervisedProcess` | `spawn`, `Task.start`, `Process.register` as a lock, `Process.sleep` outside interventions |
| `PersistentTermHotWrite` | `:persistent_term.put` refreshed on a timer or TTL |
| `TableScanCron` | an Oban worker that scans a timestamp against now and iterates (a deadline, retention or a timed rule) |
| `BroadRescue` | `rescue _ ->` that neither re-raises nor reports |
| `ExternalPostWithoutIdempotencyKey` | a POST from a configured client module without an idempotency key |

Accept: each check has tests for what it flags and what it leaves alone; Mana
itself and the `mana new` starter pass every check.

### 18. History signals rolled-back changes
`Mana.History.Record` emits the `[:mana, :history, :entry]` telemetry (the
warehouse feed) and the Moments trace from `after_action`, so a rolled-back
change is counted. Fix: emit from a notifier after commit.

### 19. Notices are not durable
The notifier delivers after commit, synchronously: a crash between commit and
delivery loses the notice, and a sender failure is recorded but never retried.
Grouping checks then inserts (two identical notices at once both go out) and
lives in one node's memory, so `group_within` does not hold across machines.
Fix: an outbox — an Oban job inserted with the change (atomic with it), a
worker that delivers and retries; grouping with `insert_new`/`update_counter`,
or in the database when the app runs on several nodes.

### 20. The offer costs a query per record and verb
`Mana.Verbs.Offered` asks `Ash.exists?` per record × verb when `when` cannot be
evaluated in memory, plus `Ash.can?` and `can_create?` per child verb. Fix:
the transformer emits one boolean expression calculation per verb, loaded
with the record in one query.

### 21. Reconcile reads whole scopes, then asks per record
`Mana.Reconcile.observe/2` reads the entire scope unbounded and calls `holds`
per record (apps' `holds` then query again). Fix: stream the scope; allow
`holds: expr(...)` evaluated in the query (select only diverging records).

### 22. Per-record locks can collide
`pg_advisory_xact_lock(hashtext(...))` is 32-bit: unrelated records can share a
lock. `Mana.NotAtomic` forces `require_atomic?: false` on every update and
destroy of every Entity resource. Fix: a 64-bit key (`hashtextextended`) in one
`Mana.Lock`; mark non-atomic only the actions that take the lock, and document
the boundary.

### 23. Errors swallowed
`rescue _ -> false` in `Mana.Verbs` (an `Ash.can?` error becomes "not offered")
and in `Mana.Reconcile` (a repair crash is dropped). Fix: rescue the specific
errors, report the rest to the error reporter.

### 24. Small idioms
- Deadline jobs are inserted on every update while `when` holds, without
  `unique:` (duplicates pile up).
- `Mana.Explore` turns plan JSON into atoms with `String.to_atom`.
- `Uploads.Confirm` is a generic action wrapping one update, filtering the
  owner with `authorize?: false`, and ignores the thumbnail enqueue result.
- The dry-run flag and the knob scope travel in the process dictionary, which
  breaks if Ash runs work in another process; action context is the idiom.

### 25. Search that apps do not rebuild
`Mana.Search` matches `ilike` on plain fields, so an app that needs accent-
insensitive matching or array fields (Host Point's map) filters in Elixir.
Fix: `unaccent` matching (with the extension required by the migration) and
array membership in `Mana.Search`, pushed into the query.

### 32. No dependency with a known advisory
`mix deps.get` reports security advisories for locked versions (ash 3.34.4,
decimal, plug_crypto in Mana; assent, bandit, jose and others in apps built on
it). Fix: update to patched versions in every package and in the `mana new`
template, run `mix hex.audit` and the advisory check in CI, and fail on any.

### 33. Erasure deletes stored files before it commits
`Mana.Privacy.erase/2` deletes an uploads resource's objects from storage
synchronously, inside the erasure; if the erasure rolls back, the rows stay
and their files are gone. Fix: delete objects after commit (an Oban job
inserted with the erasure, idempotent: a missing object counts as deleted).

## The floor (needed, not what makes it a 9)

### 26. Five minutes from `mana new` to green
Someone outside runs `mana new demo`, then the suite, on a fresh machine (Linux
or macOS host) and sees everything pass in five minutes. Fix: measure it in CI
on a clean runner (time each stage), remove every manual step it finds, and
keep the measurement as a CI job with a budget.

## What makes it a 9 — the promise the Moments spec already makes

### 27. Behaviour diff per pull request
The spec says moment × version = situation. For every pull request, the Moments
it affects run at the base and at the head, and their normalized projections
(screen, rows, offered verbs, history) are compared: "in checkout-with-coupon
the total went from R$ 90 to R$ 81, and the screen gained a button". The
reviewer, person or agent, reviews what the system does, not the lines.
Builds on #13 (snapshots, normalized version comparison).

- `moments diff --base <ref> [--affected]` writes a Markdown report and a JSON
  one; CI posts it on the pull request.
- Accept: on Host Point, a change to a price rule produces a report naming the
  Moment, the field and both values; an unchanged Moment reports nothing.

### 28. A production incident becomes a Moment
`Mana.History` (`as_of`, `fixture`) and `Mana.Privacy` together can lift a real
situation out of production, anonymized, into a Moment: "cannot reproduce"
stops existing; the agent opens the incident by name and fixes it there.

- `mix mana.incident <type>:<id> --at <time>` exports the records' history as a
  portable fixture with every personal field replaced (privacy declarations),
  and writes a recipe that replays it into a data scope.
- Accept: an incident exported from a Host Point booking contains none of the
  people's personal values and reproduces the same projection when opened.

### 29. Exploration writes Moments
A counterexample `Mana.Explore` finds and shrinks is saved as a Moment
(`saveExplorationAsMoment`): tests are discovered by the tool, not written by
hand. Builds on #13 and `Mana.Explore.save/2`.

- Accept: a seeded bug found by `mix mana.explore --save` becomes a Moment that
  fails, and passes once the bug is fixed.

### 30. Choose Moments by effect, not by import
`affected` selects Moments from Dart imports. The next step reads the Ash graph
— which actions a change touches, who calls them, what effects they have — and
maps back to the Moments whose steps and receipts reach those actions. A
backend change then finds the screens it can break. (AGENTS.md lists this as a
future capability.)

- Accept: changing a backend action's change module selects the Moments whose
  receipts name that action, and only those, plus the import-based ones.

## What turns 8 into 9 — proof

### 31. The benchmark
Mana says it is built for agents working on a running system. Measure it, the
way prefix-head measured its claim: N real Host Point tasks, each run by an agent
with Moments and without them; compare success rate, wall time, tokens and
bugs that reach the pull request. Publish the harness, the tasks and the raw
results with the framework.

- Accept: the harness runs unattended (`mana eval benchmark`), the results are
  reproducible from the published data, and the README quotes them.

## Measuring 9+

The same review, rerun after P0–P2: no correctness finding open, Postgres
paths and the runner's core under test in CI, and the Moments protocol
conformance no longer `partial` for the capabilities it lists.

## Delivered, and what remains

Proven on Mana's own suites (every Elixir package against Postgres, the
runner, the CLI, the Flutter packages; CI runs them all) and on Host Point,
a real app migrated onto it: its backend suite, every sensor, and every
Moments suite (hosts 69/69 three runs in a row, travelers, os,
municipalities, partners).

| # | Where | Proof | Limits that stay |
|---|---|---|---|
| 1–4 | `entity.ex`, `history.ex`, `privacy.ex` (notifiers after the outermost commit, deadline recheck under lock, savepointed history, history scrubbed on erasure) | `entity_postgres_test`, `history_postgres_test`, `privacy_postgres_test` | — |
| 5 | `test/support/postgres` harness (`MANA_TEST_POSTGRES`) | every `*_postgres_test` | — |
| 6 | `.github/workflows/ci.yml` (+ `moments-diff.yml`) | each job run locally as CI runs it | not yet run on GitHub |
| 7 | session (46), contracts (15), runner sandbox/suite tests | mutation checks: each guarded line fails a test | — |
| 8 | progress-following waits; one report at a time, out-of-order reports refused; a relaunch releases the previous app | `progress_test`, `moment_navigation_test`, `observations_test`; Host Point creation journeys 10/10 | — |
| 9–10 | `notification_groups.ex`, `knob_cache.ex` (supervised) | `notice_groups_test`, `knob_cache_test` | grouping is per node |
| 11 | `cli/lib/src/client.dart` on `package:analyzer`; `package:mana/runtime.dart` | `client_test` | — |
| 12 | `moments/lib/src/child_process.dart` (process groups) | `process_group_test` | — |
| 13 | fork, diff, trace, save; checkpoint composition, parent materialization, preparation recovery, navigation without criteria | `situations_test`, `conformance_test`; conformance **full** | the launcher runs one UI per app (fork is the situations profile's) |
| 14 | `platform.dart` (Linux, macOS), `ios_transport.dart` | `platform_test`, `ios_transport_test` | macOS and iOS verified with fakes only |
| 15 | `app:` per moment; Host Point's 172 Moments in 16 feature domains | `manifest_apps_test`; identical manifests before/after | — |
| 16 | `ash/upgrade`, `mana upgrade` | upgrade tests | two codemods |
| 17 | `ash/lint` (19 checks, no suppression comment; `mix mana.lint` folded in) | 69 lint tests; zero findings in Mana and Host Point | — |
| 18–25 | history signal notifier; notice outbox; one-query offers; expression `holds:` in the query; `Mana.Lock`; typed rescues; `update :confirm`; unaccent and embedded-array search | the tests named in each package README | — |
| 26 | pinned JRE in the contracts toolchain; `mana doctor` names missing tools | first-green from a cold HOME: 100.6 s (budget 300 s) | Docker image pull not measured |
| 27 | `moments diff --base <ref>`: rows, history, observation, declared screen, offered verbs | `behaviour_diff_test`; Host Point price rule: R$ 80.00 → R$ 72.00 named, unchanged Moments silent | the screen shows what an app declares in its projection |
| 28 | `Mana.Incident` with `personal [...]`, people as roles, recorded-order replay | `incident_postgres_test`; Host Point booking: no personal value, same projection reopened | collection follows `belongs_to` from the subject |
| 29 | `explorations "dir"`; `mix mana.explore --save`; `/_explorations/check` | `exploration_moments_test`: a seeded bug's Moment fails, then passes once fixed | no screen (`up`/`open` refuse it) |
| 30 | `Moments.ActionGraph`; recipe preparation traced; receipts | `effect_selection_test`, `action_graph_test`; Host Point: one change module selects 10 of 42 | screen loads give no evidence; per-file granularity |
| 31 | `mana eval benchmark`, `framework/benchmark` (12 tasks, two conditions) | harness tests with a scripted agent; every task validated (no-op fails, the real fix passes) | **no model run yet**: it spends tokens and waits for the owner's go-ahead |
| 32 | ash 3.37.2, ash_postgres 2.15.2, decimal, plug_crypto, assent 0.3.2 | `mix hex.audit` 0 everywhere; CI fails on any Hex, Dart or Flutter advisory | — |
| 33 | `Mana.Uploads.Discard` (Oban job or notifier after commit) | `erasure_storage_test` | without Oban the deletion is not retried |

Found while migrating Host Point and fixed in Mana: reconcile `holds:`
negations (SQL precedence), explore rebuilds colliding with identities,
explore log noise and determinism (record order, input draw order, first run
on a new database), replays across records in recorded order and from a
seed, incidents keeping business fields, notices dropped with quieted
deadlines, lookups set aside as dependents.

