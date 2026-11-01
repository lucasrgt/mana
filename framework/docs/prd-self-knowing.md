# PRD — An app that knows what it can, did, must and would do

Status: delivered · Owner: Mana · Target: v0.2.0

## Why

Mana already answers most questions an app can be asked about itself, each
through a primitive declared once:

| Question | Primitive today | Gap this PRD closes |
|---|---|---|
| What can happen **now**? | `Mana.Verbs` (`when`, policies, knobs, flows) | every reachable "now" is never visited |
| What **happened**? | `Mana.History` | — |
| **Why** is this on screen? | `Mana.Why` | it stops at the Moment, not at the control that was pressed |
| What **must** hold? | `Mana.Reconcile` | checked against today's rows only, never against states the app can reach, never against time |
| What **will** happen? | `Mana.Entity` deadlines, `Mana.Flow`, `Mana.Intervene` | no way to say "within 15 minutes" |
| What **would** happen? | `Mana.Checkpoint`, `Mana.History.replay` | never run over real traffic against a new version |

Moments prove situations someone wrote down. The declarations above already
describe the space those situations live in. This PRD turns that space into
something Mana walks, snapshots, diffs and links, **without asking apps to
declare anything new** beyond two optional options. A capability that needs a
new block of DSL to work is out of scope.

## Principles

1. **Derive, don't declare.** Every guarantee comes from what verbs, views,
   flows, entities, history and reconcile rules already say.
2. **Unavailable is not green.** Every report says what it could not check.
3. **Development only by default.** Scopes, snapshots and exploration are off
   unless the app configures them (as knob scopes are).
4. **Receipts.** Every run can be turned into an AVP verdict.

## Capabilities

### 1. Explore — `Mana.Explore`, `mix mana.explore`

The app searches its own state space. A run starts from an empty or seeded
store, then repeatedly picks an actor and a **move**: a verb the actor is
offered on a record (`Mana.Verbs.offered/2`), a collection verb it may start
(`Mana.Verbs.available/2`), or the clock (fires due `Mana.Entity` deadlines).
Inputs come from `Ash.Generator.action_input/3`; ids of related records are
picked among records that exist.

After every move it checks properties **derived from declarations**:

| Property | Derived from | Violation |
|---|---|---|
| `offer_honest` | `verbs` | an offered verb's action is refused by policy or by its own `when` |
| `refusal_enforced` | `verbs` | a verb that is not offered (its `when` fails) is accepted by the server |
| `idempotent` | `idempotent: true` | running it twice changes the record differently than once |
| `inverse_restores` | `inverse:` | verb then its inverse does not restore the fields the verb changed |
| `invariant` | `reconcile` | a `desired` rule diverges in a reached state |
| `eventually` | `reconcile ... within:` | a record stays in scope past `within` after the clock advanced |
| `flow_monotonic` | `flow` | a flow cursor moved back |
| `flow_deadlock` | `flow` | a record not `done` offers no verb to any actor |
| `history_replays` | `history` | `Mana.History.replay/3` of a record's log does not rebuild its fields |

Each violation is shrunk to the shortest move sequence that still fails and
can be written as a **Moment trace** (`moments/explore/<name>.json`) that
`Mana.Explore.Recipe` replays as a backend recipe. A run reports coverage
(verbs declared vs. reached) and the **affordance graph**: abstract states
(a record's enum/boolean/atom fields, the "shape") with the verbs each actor
is offered there.

Acceptance:
- A seeded bug of each property kind is found, shrunk and reported.
- A clean resource produces zero violations and full coverage of reachable verbs.
- Runs are deterministic for a given `seed`.
- Exploration never touches outside systems: `external:` and `risk: :money`
  verbs are skipped unless the app opts in with `external: :run`.

### 2. Snapshots and data scopes — `Mana.Snapshot`

On Postgres, a situation's data is a database cloned from a template
(`CREATE DATABASE … TEMPLATE … STRATEGY FILE_COPY`).

- `base!/1` builds (once per migration set) a migrated template.
- `open/2` clones the base or a snapshot into a **data scope**: its own
  database and its own dynamic repo.
- `capture/3` freezes a scope into a named snapshot; `fork/3` opens N scopes
  from one snapshot; `drop/2` releases.
- `diff/3` compares two scopes by their `Mana.History` entries since they
  diverged and by row counts per table.
- `Mana.Snapshot.Plug` runs each request carrying `x-mana-data-scope: <id>`
  on that scope's repo (honoured only with `config :mana_core, data_scopes: true`),
  so suite workers stop sharing one database.

Acceptance: two forks of one snapshot written independently do not see each
other; capture → open reproduces the same rows; the header is ignored when
scopes are off; diff of a scope with itself is empty.

### 3. Controls that know their verb

`VerbGate` and `runVerb` take an optional `recordId` and mark the control
with `ValueKey('verb:<type>.<verb>[:<id>]')`, and while Moments run they
register what they offer in `MomentAffordances`. Consequently:

- A Moment step may say `step(:pay, verb: {:booking, :pay})`; the gesture
  driver finds the control by that identity. The exporter refuses a verb the
  named resource does not declare: the link gesture → verb is checked when the
  manifest is built, not discovered at runtime.
- New check kinds `:offered` / `:not_offered` (`verb: {:booking, :pay}`) read
  what the screen offers without a hand-written projection.
- `Mana.Why` names the control (`verb:booking.cancel`) whose gesture set a value.

Acceptance: a Moment written only with `verb:` steps and `:offered` checks
passes headless against the starter; a step naming an undeclared verb fails
export.

### 4. The program graph — `mix mana.graph`, `mana graph`

One graph derived from Spark introspection and the Moments manifest: nodes
for features, resources, verbs, views, flows, reconcile rules, knobs and
Moments; edges for owns, offers, guards (`knob:`), proves (Moment steps and
checks naming a verb), inverse, step-of. Canned queries:

```
mix mana.graph verbs-without-moment
mix mana.graph proves booking.pay
mix mana.graph knob coupons_enabled
mix mana.graph dead-verbs      # neither a Moment, an agent entry nor a screen offers it
mix mana.graph --json
```

`mana graph` adds the Dart side: which verbs screens reference
(`XVerbs.<verb>`), so `dead-verbs` counts screens too.

Acceptance: queries answer from a fixture domain exactly; `--json` is stable.

### 5. Rules with time — `reconcile ... within:`

```elixir
desired :accepted_resolves, "an accepted booking is paid or expires within 15 minutes",
  scope: expr(status == :accepted),
  within: {15, :minute},
  since: :updated_at
```

A record in `scope` diverges only once it has been there longer than
`within` (measured from `since`, a timestamp field, `updated_at` by default).
The same rule is an `eventually` property in exploration, where the clock is
virtual.

Acceptance: a record in scope younger than `within` converges; an older one
diverges with its age in the detail; exploration finds a deadline that
never fires.

### 6. Production replay — `mix mana.replay`

`mix mana.history.export` already writes a redacted log. `Mana.Replay.run/2`
replays every subject of an exported log against the code compiled now, each
inside a transaction that is rolled back, and compares the rebuilt record to
the recorded final `after`. The report groups subjects by feature: replayed,
same, diverged (with the fields), refused (external verbs, missing actions).

Acceptance: a log recorded under one implementation and replayed under a
changed one reports exactly the subjects whose outcome changed; nothing is
written.

### 7. Affordance lock — `affordances.json`, `mix mana.affordances`

Exploration with a fixed seed writes the affordance graph to
`affordances.json` in the backend: for each resource, each shape, each actor,
the verbs offered. It is committed, so a pull request shows behaviour changes
as a diff a person reads ("`cancel` is no longer offered to `host` when
`status: paid`"). `mix mana.affordances --check` fails when the file is
stale and prints that sentence diff; `mana doctor` runs it when the file exists.

Acceptance: changing a `when` changes the lock; `--check` names the verb,
the actor and the shape.

### 8. Undo from history — `Mana.Undo`

Inverses become a product feature beyond the toast `VerbGate` already shows:

- `Mana.Undo.last(record, actor)` — the newest history entry this actor made
  on the record whose verb declares an inverse that is offered now.
- `Mana.Undo.undo(record, actor)` — performs that inverse, recording it with
  `undo_of` pointing at the entry.
- Flutter `HistoryView` offers "Undo" on such entries (`undoable:` callback).

Acceptance: undo of an inverse-declaring verb restores the fields; a verb
without inverse, or whose inverse is not offered, is not undoable; the
history entry of the undo names what it undid.

## Non-goals

- Proving pixels; generating widgets; model-checking concurrency between
  processes (exploration is sequential); exploring outside systems.

## Rollout

Each capability ships with its tests in the package it lives in, a catalog
entry in `catalog.toml` and the regenerated skill. Host Point moves to the
release and adopts: exploration of its verb-heavy resources, the affordance
lock, `within:` on its deadline rules, verb-identified Moment steps and the
graph in `mana doctor`.

## Delivered, and what remains

| # | Where | Tests | Limits that stay |
|---|---|---|---|
| 1 | `ash/core/lib/mana/explore.ex`, `mix mana.explore` | `explore_test.exs`: a seeded bug per property is found and shrunk; a clean resource breaks nothing and covers every verb | Sequential (no interleaving between processes); ETS resets by itself, Postgres needs `reset: Mana.Explore.snapshot_reset(repo)`; `holds` functions that call outside systems need `skip_rules:` |
| 2 | `ash/core/lib/mana/snapshot.ex`, `Moments.Recipes` `data_scope: true`, live_ui `MomentDataScope` | `snapshot_test.exs`, `recipes_data_scope_test.exs` (Postgres, `MANA_TEST_POSTGRES`) | Oban queues and Ash async loads do not follow a scope; the runner's own `fork`/`diff` verbs stay off (`protocol.dart` conformance flags unchanged) — isolation comes from data-scoped recipes |
| 3 | `Moments` DSL/manifest, runner, `VerbGate(recordId:)`, `MomentAffordances` | manifest, runner, mana_command, live_ui tests | Controls drawn outside `VerbGate` need `VerbGate.keyFor`; an offer proves the control was drawn, not that the server accepts; `mix moments.review` does not read the link yet |
| 4 | `ash/core/lib/mana/graph.ex`, `mix mana.graph`, `mana graph` | `graph_test.exs`, `cli/test/graph_test.dart` | Screens are found by `XVerbs.y` references, not by what renders |
| 5 | `Mana.Reconcile` `within:`/`since:` | `reconcile_within_test.exs`, `eventually` in exploration | Age is measured from one timestamp field |
| 6 | `ash/core/lib/mana/replay.ex`, `mix mana.replay` | `replay_undo_test.exs` | Needs a database holding what subjects refer to; on a data layer without transactions the rebuilt record is destroyed, not rolled back |
| 7 | `Mana.Explore.Lock`, `mix mana.affordances [--check]` | lock tests in `explore_test.exs` | A change in generated inputs can move which shapes are reached; the diff then says a shape is newly or no longer reached |
| 8 | `ash/core/lib/mana/undo.ex`, `HistoryView(me:)` | `replay_undo_test.exs`, `history_view_test.dart` | Only the newest change of a record is undoable |
