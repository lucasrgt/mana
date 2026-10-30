# Moments — development runner

Moments is the runner of named, navigable situations for Mana apps (Ash backend +
Flutter client). It opens a situation by name, keeps it alive while you edit,
verifies its declared criteria and selects the Moments a change affects. The protocol it implements is in
[protocol-v0.1.md](protocol-v0.1.md); the Markdown map parser
(`lib/src/format.dart`) and the runtime adapter (`lib/src/runtime.dart`) follow it.

The runner is written in Dart: `framework/moments/moments` compiles
`bin/moments.dart` when its sources change, and its tests run with
`(cd framework/moments && dart test)`.

## Protocol profile

Moments is the protocol of navigable situations; Mana implements its
Ash/Flutter profile. The 0.1 specification shipped here has its SHA-256 pinned
in `lib/src/protocol.dart`. Changing that text requires reconciling the
declared capabilities; this identity check does not certify conformance.
`moments capabilities --json` works outside a project and exposes the engine's
capabilities and limits. It reads no private data and proves no journey.
Discovery declares `executionProfiles.launcher`; no command flattens a child
into a root.

The Ash DSL accepts `from(:parent_name)` on a Moment. The exporter resolves
ancestry after collecting every domain and refuses missing parents and cycles.
`base` is shared backend preparation; it is not the parent. Ancestry produces
manifest format **3**, identified as protocol **0.1**, profile
`mana-ash-flutter`. These versions are independent. Older catalogs without
ancestry stay in formats 1/2; declaring `from` in those formats is refused.
Older engines refuse format 3, so a transition is never ignored and run as a
root.

`moments graph --json` derives nodes and edges exclusively from that catalog.
The result is a `declared-map` with `execution: null`: it does not infer
ancestry from routes, step order, shared recipes or test results.
`graphFromMap` accepts an authored `MOMENTS.md` and produces the same
representation. There is no second dependency file.

A child is never opened, prepared or run: `from` records lineage for the map.
Share setup between Moments through a backend `base` recipe instead.

`open --fresh` resets presentation; `up --fresh` runs the app's preparation;
`reset --discard-data` discards the stopped database. None of them is the
specification's `reset` to the origin. Navigation stays distinct from
verification: the map and the export accept Moments without criteria.

Focused contract check (no backend or Flutter):

```sh
(cd framework/moments && dart test test/protocol_test.dart)
```

`framework/ash/moments/tool/prove_lineage.exs` compiles real domains in the Mix
consumer, exports the fixture to an explicit path and refuses cycles and
missing parents. Pass the exported file in `MANA_LINEAGE_MANIFEST` to the Dart
test to also compare the real Ash export with the Markdown map. Without it, that
case is skipped explicitly; the others use protocol fixtures.

## Short CLI

The command is `framework/moments/moments` (or a `moments` link on your `PATH`);
the first run does `dart pub get` and compiles the executable into
`.dart_tool/`. `moments tools` compiles the import parser used by `affected`.

```sh
moments up notifications            # keep running in a terminal
moments up notifications --fresh    # prepare data and UI again, explicitly
moments refresh --check             # after saving Dart; readable summary
moments suite notification-read --headless  # prepare, tap the UI and check in Ash
moments recover                     # after inspecting an interrupted journey
moments open notifications          # resume the saved state
moments open notifications --fresh  # reapply the initial UI recipe
moments status --json
moments status --local --json       # resources and preparation without the bridge
moments down                        # stop/recover the instance, keep the database
moments reset --discard-data        # discard the stopped isolated database, keep proofs
moments inspect --json
moments affected --base HEAD --json # selection plan, runs no criteria
```

The app is chosen by the current directory, the nearest `.moments.json` or
`--project <dir>`. The short CLI delegates to the same engine and keeps its
reports in `.proofs/`. No criterion is inferred from formatting: `refresh`
without `--check` only requests a refresh, and `inspect` only observes. Invalid
arguments fail before any action; `--json` also produces a structured error.

### Saved presentation compatibility

The private session file accepts the legacy **unversioned** projection and the
`version: 2` format with `active` and `states`. Unknown explicit versions,
including `version: 1`, are refused without rewriting the file. The next valid
save converts the legacy format to 2; there is no automatic migration of app
data.

A changed declaration may add explicit defaults when the route is the same.
Values already saved win and stay subject to the current contract: removed
fields, incompatible types or values dropped from an enum cause a refusal.
`restore: false` fields are observations, not restore inputs. Saved routes the
contract still allows can be resumed; changing the declared route does not
allow merging the new defaults with the previous route.

`open` with preparation also validates the **inactive** destination before
running its backend recipe. The `up` launcher does the same before taking over
the infrastructure and again before the recipe, after asynchronous startup. A
compatibility refusal does not change the saved presentation. `fresh` is the
explicit choice of the declared projection for that destination; it does not
recover an unknown session format or allow silent value conversion.

This property is `guaranteed` within the validation that precedes preparation.
There is no transaction between the manifest, local files and the database: a
declaration changed during a recipe already started may be detected after
effects happened. That failure needs inspection; it is not proof of rollback.

### Suite workers sharing one web build

With several workers, the suite serves one compiled bundle through
`WebActor.start(surfaces: ...)`, a map of worker IDs to `{bridgeUrl,
bridgeToken}`. All use the same bundle, web origin and API; each keeps its own bridge, runtime
claim, observations and gesture channel. Bootstrap version 2 selects only the
interface named by `momentsActor` and confirms the same ID in Dart. A missing,
duplicate or unknown selector is refused, with no default bridge.

This is a routing boundary, not security isolation between interfaces on the
same origin: they share storage and run trusted local code. The IDs are not
credentials. It does not copy the database and does not change
the Moments' `from` ancestry. The dynamic path is debug/loopback only; regular
and release builds never fetch the bootstrap.

### Latency profile of the same journey

`moments profile <name> --json` runs the declared journey once, with the same
preparation, gestures and criteria as the suite. Writes that are part of the
journey happen normally; there is no automatic repetition to collect samples.
It uses the local launcher, without concurrent load.

The normal report in `.proofs/` gains `profile`: separate times for
declaration, ownership, preparation/restore, steps, verification and closing.
With the opt-in Ash/Dio integration it includes the duration of the requests
the gestures caused, inclusive action spans and aggregated Ecto queries. It
never sums nested spans or subtracts request time from the total to infer
frontend time.

Missing, legacy or truncated diagnostics produce a `partial` profile and exit 2
when the journey passed; `journeyStatus` keeps the functional result. No SQL
event observed means unknown, not zero queries. Detached jobs, CPU, heap, load,
multi-run percentiles and production cost are not covered.

### Selecting Moments from Dart code

The DSL can declare the libraries that make up a screen or journey:

```elixir
client_roots(["lib/features/bookmarks.dart"])
```

These roots are added to `watch` automatically; a project from `mana new`
already declares them. A journey that crosses screens needs the roots of all of them.

With the [Dart parser prepared](../flutter/devtools/README.md),
`moments affected --base <commit>` follows imports, exports, parts,
conditional imports and local dependencies resolved by Pub. When every Moment
has roots and they match the Git base, a change mapped in `lib/` can select
only the Moments that import it transitively. The plan reports `dart-imports`,
the paths that caused the selection and their source identity. It runs no
gesture, prepares no data and is not test evidence.

For Dart, the selection stays broad on changes to shared packages,
composition/routing without an owner, Pub metadata, changed roots, a removed
catalog, unmapped sources or an unavailable parser. A syntax error or an
incomplete local import also widens it. A stale Ash declaration makes the plan
unavailable and asks for `sync`. The graph covers static directives, **not**
dynamic calls or dependency-injection effects.

### Services declared by the app

The runner only uses `services`: each app supplies `prepare`, `compile` and
`serve` commands, a directory, a port, watched sources and a `ready` function.
The engine tracks identity, failure, refresh and shutdown; it knows nothing
about the product's tables, Phoenix or recipes. The default database is
`postgres:16`; an extension requirement belongs to the adapter.

Each service receives `PATH`, `LANG=C.UTF-8`, its own private `HOME` and
`TMPDIR` and the supervisor's `MANA_RESOURCE_*` identifiers. Other variables
only come in through `environment: {KEY: 'value'}` in the service declaration.
The terminal environment is not forwarded wholesale: database URLs,
credentials, proxies, `NODE_OPTIONS` and `DOCKER_HOST` do not leak in by
accident. `HOME`, `TMPDIR` and `MANA_RESOURCE_*` cannot be overridden.

Each service directory is `moments/.backend/services/<name>`, with its
temporaries under `tmp`; logs stay in `.backend/<name>.log`. Invalid
declarations fail before the instance is created. A compile failure keeps the
previous server, but the diagnostics record the unapplied revision and prevent
treating it as current proof.

### First Flutter connection and pending edits

`waiting-runtime` means the Flutter compiler/server is up but the app has not
yet made its first observation of the Moment. The watcher keeps recording
edits; it does not try to restart a runtime that has not appeared. Open the app:
once it observes the current revision, the watcher applies the last pending
edit automatically. A transport connection without an observation does not
release the refresh, and the initial observation does not count as proof of
updated code.

`check` and `refresh --check` before the connection return unavailable with that
guidance. An early refresh keeps the queue intact.

### Shutting down and recovering the instance

`moments down` stops the current project's instance. With a live supervisor, it
uses its authenticated bridge and waits for shutdown. If the supervisor already
died, it recovers that run's recorded resources. The result reports
`graceful`, `recovered` or `already-stopped`; it never deletes the database,
uploads, UI state or proofs, prepares scenarios or repeats gestures.

The launcher records PID + process start + host boot, the run identifier and
the workspace. Children and observed descendants are recorded; Docker services
use instance, run, workspace and role labels. Custom Docker adapters use
`momentDockerLabels()` and inherit the environment the supervisor provides. Do
not put secrets in labels. External resources created without this contract
cannot be cleaned up by name or port.

The operation uses `/proc` and `flock` on Linux. The kernel lock serialises
down/up and is released when the process dies, with no TTL or manual file
removal. Flutter and its runtime use `TMPDIR=.backend/tmp/flutter-<runId>`, so
compilation and DevFS stay inside the instance. A port held by an unidentified
process, a legacy/corrupt journal or a container with a divergent identity make
the command refuse to finish and keep the evidence. There is no `--force`.
macOS/Windows hosts still need an identity/lock adapter; this does not limit
the targets Flutter compiles to.

### Incomplete initial preparation and explicit discard

The instance's identity and credentials are persisted before its Postgres is
created. New databases carry owner, workspace and role labels. If the crash
happens after Docker created the database but before its port was saved, `down`
finds and stops that same database. The next `up` can resume creation with the
recorded identity.

Before running the app's preparation, the instance writes a checkpoint with the
Moment and the stage (`startup`, `base`, `services` or `recipe`). It is removed
only when preparation and its inspection finish. If the process dies in that
window, the next `up` refuses to repeat the writes.

`moments status --local` inspects identity, processes, database and stage
without loading the app's adapter, without the bridge and without showing
credentials.

After inspecting, `moments down` keeps the incomplete database. To discard that
development environment, use `moments reset --discard-data`. It requires the
run to be stopped and a stopped database with a proven identity. It removes only
that database/volume and its resume states, keeps `.proofs/` and records the
discard without credentials. The reset records its intent before removing the
container; if it dies in between, another `reset --discard-data` finishes the
same discard. `up` cannot cross a pending reset.

### Interrupted journey and durable intent

A journey records ownership in `moments/.backend/.journey.json` before preparing
data. Before delivering each gesture, it writes its intent (kind, ID and
target) with fsync and an atomic replace. The record holds no typed values. A
write failure prevents delivery; the intent record alone does not confirm the
effect.

If the supervisor dies, `down` keeps this record. The next `up` opens the held
journey in inspection mode, even when another Moment was requested. It
recompiles and serves the services without their initial preparation and
without reapplying the scenario's recipe. New journeys, preparations, refresh
and gestures are blocked; edits stay pending. `status` shows the last intent;
`inspect` lets you check UI and backend. After checking the effects, `recover`
releases the instance without undoing or repeating actions. Only a new journey
prepares and runs again.

This file is local operational state, distinct from the disposable proofs in
`.proofs/`. Do not delete it to unblock a run. The protection belongs to the
named journey; loose gestures without a lease do not get it. It does not
implement exactly-once in the domain nor roll back a partially run recipe.

### Refreshing on the same screen

Dart edits use hot reload when the connected runtime advertises the new
observation capability. The engine waits for the compiler, sends an ephemeral
challenge and only marks the code as applied after a new frame and a read of the
active binding. The challenge belongs to the revision and the runtime: old
observations, tab/runtime switches, ambiguous bindings and code changes during
the cycle fail. No step, preparation, navigation or restore is triggered by the
reload. `refresh --check` adds the Moment's UI and backend criteria.

Use `moments refresh --restart --check` for changes to `main`, `initState`,
initializers or anything the SDK cannot reload. Scenario preparation and
backend changes use restart automatically. The engine never retries a rejected
compilation or turns a reload failure into another silent run.

`MomentViewBinding` and `MomentDraftBinding` register their readers
automatically. The screen must be ready and have a single active binding for
the declared route. Use stable identities for stateful widgets: a key derived
from a translated title can destroy the scroll position when the text changes.
The report states `refresh.strategy` (`reload` or `restart`). `totalMs` measures
the refresh after it is triggered. `waitMs` is the time from the watcher seeing
the save to the refresh starting (debounce plus any refresh still running); it
is `null` for a manual refresh with no detected change. The time from the write
itself to the watcher seeing it is not measured.

### Resume blocked by the session

The app can wrap its session gate in `MomentRuntimeBlocker`, with
`authenticationRequired` or `sessionUnavailable`. The first asks for a login
through the normal flow; the second says the session could not be verified.
Declaring the reason does not authenticate, repeat the recipe or change the
saved draft. A Moment whose own situation is anonymous, like the login screen,
must not declare a missing session as a blocker.

The bridge advertises `runtimeBlocker: 1`. Reports use revision, runtime owner
and an increasing sequence; they accept no free text or credentials. While
blocked, captures, observations and frame acks are refused. Removing the block
needs a new observation to prove restoration.

The supervisor reports `phase: error`, `failureStage: runtime` and the typed
reason. `refresh --check` produces `unavailable` (exit 2), without running the
criteria or repeating actions. After resolving the session in the app, run
`refresh` again.

### Selection from the compiled Ash backend

`moments sync` also exports `backendGraph`: the `mix xref` file graph (runtime,
export and compile edges), the resources reflected by
`Ash.Domain.Info.resources/1` and SHA-256 hashes of the sources. Collection
happens on the explicit export; `affected` stays offline and never starts Mix
or Docker.

`elixir-compiled` precision requires current sources, a complete inventory and
the same graph/resource structure in the Git base. A content edit can select
only the Moments whose domain/resource depends on that file, transitively. A
shared dependency selects all of its consumers. Added/removed files or edges,
environment/root changes, stale hashes, symlinks, metadata/configuration and
unowned paths widen the selection. Mixed Dart and Elixir changes use the union
of both graphs' Moments (`dart-and-elixir`). If either side is unavailable or a
path is unmapped, the whole plan stays broad.

The graph does not resolve dynamic dispatch, modules chosen at runtime or
external services. An unknown xref format marks the evidence unavailable without
blocking the DSL export. Hashes are verified again before the plan finishes;
the runtime still requires its own proof of applied code and postconditions.

A step's postconditions are kept in `steps[].checks`, with timings, even when
the journey fails. The backend identity before the run is kept in
`code.backendAtStart`. Code, process, target or observation invalidated while
waiting result in `unavailable`; an old postcondition is never reused as a
current failure. Agreement between UI and database does not replace an
action's postcondition.

### Selection from changes

`moments affected` compares commit `HEAD` with the current checkout, including
staged, unstaged and new non-ignored files. `--base <revision>` picks another
exact commit, with no implicit merge-base. It works offline: it does not import
the backend adapter, open an instance, prepare data, trigger gestures or write
proof. The `planned`/`executed: false` result is a plan, never an approval.

When only local declarations changed, it compares each exported Moment with its
version in the Git base, including criteria, steps, source and the screen
contract. Selection is by exported identity; several Moments in the same DSL
file may come in together because they share its hash. This precision assumes
`app/moments/` holds development tools/declarations, never logic imported by
the production runtime.

Configuration, shared packages, unknown files, deletions or an unavailable
graph select the whole catalog. `watch` serves refresh and is not treated as a
complete graph. Even unknown documentation widens the selection. A missing
catalog in the base also selects everything; a stale or inaccessible DSL source
returns `unavailable`/exit 2 and asks for a sync. There is no silent empty
selection when evidence is missing.

The JSON lists `selected`, `omitted`, `removed`, `changed` and the reasons for
widening. `moments suite --affected --project <app>` runs the selection.

Renames count on both ends; deletions and new files take part. Paths with
spaces or newlines use Git's NUL protocol. `--base` is only valid for
`affected`; an invalid revision fails before anything runs. Exit 0 only means
the plan was computed.

## Opening, starting and running

`open <name>` resumes the saved projection; `open <name> --fresh` reapplies the
recipe's initial values and replaces only that Moment's saved UI state. The
database is not recreated and the other Moments are kept. The preparation recipe
may change the isolated data the scenario declares. Both wait for the runtime's
observation; opening runs no criteria.

`up <name>` resumes the private context of that Moment's last completed
preparation, without running its recipe or the services' preparation again. The
services start normally. The persisted receipt identifies name, recipe and
base; it does not promise the recipe's code stayed the same. Changes that need
migration/preparation should use `up <name> --fresh`: it runs the preparation and
reapplies the initial UI, keeping the existing database and the other UI states.
It does not run a journey's steps. On first start, `up` prepares normally.

An old instance without a receipt, or one prepared for another Moment, needs
inspection and an explicit `--fresh`; the engine does not guess where private
data came from. An interrupted preparation stays on the `--retry-preparation`
path; an interrupted journey opens for inspection and needs `recover`. `--fresh`
cannot bypass those paths nor be combined with `--retry-preparation`.

### Journeys

A journey requires steps declared in the Ash DSL. It prepares and opens the
situation once, fires real events through Flutter's gesture system and waits for
the postconditions of each step that declares `until`. After the last step, it
waits for the final criteria for up to 12 s, repeating only observations. The
declaration does not need to duplicate the final criteria in the last step's
`until`. Intermediate taps still need `until` to order the transition before the
next gesture.

The driver taps, long-presses and swipes widgets with a stable key that are
visible and reachable by hit testing, fills and submits text fields through
private references, reveals targets (building ones a lazy list has not built
yet) and presses the platform's back. It never calls business callbacks
directly. `moments capabilities --json` lists every gesture, the surfaces they
reach, how backend state is set up and observed, and the limits. Receipts include optional diagnostics (dispatch
request time in the CLI, queue and delivery→response in the supervisor, frame
wait and execution in Dart, postcondition wait). They are durations from
separate monotonic clocks; timestamps from different processes are never
subtracted. Missing or invalid metrics neither pass nor fail the journey. A
timeout after a gesture was delivered is an uncertain result: inspect before
running again.

```elixir
step(:email, fill: "session.email", from: "login.email")
step(:password, fill: "session.password", from: "login.password")
step(:show_action, reveal: "session.submit")
step(:sign_in, tap: "session.submit", until: [:authenticated, :destination, :session_persisted])
```

The other gestures:

```elixir
step(:search, submit: "search.field")                       # the keyboard's action key
step(:next_photo, swipe: "gallery.pages", direction: :left) # left, right, up or down
step(:row_menu, long_press: "list.row")                     # held past the long-press timeout
step(:close, back: true)                                    # the platform's back button
```

`submit` focuses the field and calls `EditableTextState.performAction` with the
field's own `textInputAction`, so `onSubmitted` runs as from the keyboard.
`swipe` drags the target's centre across 60% of its size in pointer moves, so
page views, carousels and dismissibles move as under a finger. `back` sends
`popRoute` on `flutter/navigation`, as the system button does: the dialog or
sheet on top closes, or the router's back dispatcher decides.

`fill` points to a `ValueKey<String>` holding exactly one `EditableText`. The
driver taps the field to focus it and hands the text to the public
`EditableTextState.updateEditingValue` entry point, so Flutter's formatters and
`onChanged` take part normally. It never assigns the controller or calls
business callbacks. It does not prove the system keyboard, IME composition,
autofill or native accessibility. Read-only, ambiguous, hidden or unfocusable
fields are refused. The current limit is non-empty text of up to 4096 UTF-16
units.

`reveal` uses `Scrollable.ensureVisible` to bring a `ValueKey<String>` into its
scrollables. A target a lazy list has not built yet (a long select menu, a
`ListView.builder`) is first searched for by paging through the mounted
scrollables, the topmost popup first, at most 200 pages; the ones where it
never appears go back to where they were. A `tap`, `fill` or other gesture on a
target out of view scrolls to it the same way before hit testing, and waits (up
to 6 s, within the gesture's deadline) for a target that is still loading,
animating, covered or disabled.

Things outside the app (a payment page, a chat app, the browser, the phone's
maps) never take the screen in a Moment: the app opens them through
`MomentHandOff.open(label, launch)` from live_ui, which in a running Moment
records `label` in `MomentHandOff.opened` instead. The app reports it as a
`handOff` field, and the recipe plays what the other side would do, such as the
webhook a payment provider sends.

A recipe whose journey needs settings of its own opens a knob scope
(`Mana.Knobs.scoped/2`) and returns it in its launch as `knobScope`. The app
then sends `x-mana-knob-scope` with every request, and its backend
(`Mana.Knobs.Scope` in the request pipeline, `config :mana_core, knob_scopes:
true` outside production) reads and writes that scope's values; `observe` runs
inside it. Moments running beside it keep the shared values, so one can turn a
setting off without the others seeing it.

`from` is a name, never the value. The app's local adapter implements
`resolveInput(instance, reference)` and decides which fixtures it offers. The
bridge only accepts the reference/target pair declared on the active Moment. It
hands the value once to the owning runtime and drops the reference; receipts
and reports only hold the delivery status. Resolution never happens in the CLI.
The app must also avoid copying passwords into projections, logs or observable
fields.

The `finalObservation` receipt records attempts, duration and budget of the
final wait. Each sample requires the same revision, Flutter runtime, DSL
sources, runtime Dart digest and backend processes, plus coherent projections
between `look` and `inspect`. Every Dart file is reread in full when the check
starts and before it reports, off the event loop the bridges share; between
samples the runtime's digest stands in for that reread. That digest is reused
until a file event arrives (or for at most a second), so an edit is seen once
its event lands rather than at the instant of the write; marking refreshed code
applied always rescans. Steps and the final wait read `look?after=<n>&wait=<ms>`,
which answers as soon as the screen sends its next report. An identity, source or transport change stops as `unavailable`,
without repeating gestures or preparation. When the wait runs out, a last
coherent observation that contradicts the criterion is `failed`; missing
coherent evidence is `unavailable`. That wait belongs to journeys; `refresh --check`
observes a coherent situation without waiting for false
criteria to become true.

Flows across several screens can keep a binding in the development shell, with
a stable entry route and an observed/restorable current destination. Session
identity and phase are observations only (`restore: false`); restoring the
destination never authenticates the user and the normal guards stay active.

During a journey, the instance has one exclusive owner. Other commands that
open/reset situations, prepare data or start a manual refresh are refused.
`status --json` shows the ownership in `journey`; reading and inspection stay
free. Success releases the ownership. Failure or expiry keeps it to avoid
another automatic write over an uncertain result. After inspecting the effects,
`recover` releases the instance without repeating or undoing actions.

### Intermediate journey criteria

A criterion has final scope by default. `scope: :step` marks a condition that
must hold during a step without having to persist in the result:

```elixir
step(:login_screen, tap: "recovery-sign-in", until: [:login_screen])
check(:login_screen, kind: :ui_equals, field: :destination,
  equals: "/sign-in", scope: :step)
```

The exporter and the engine require every intermediate criterion to be tied to a
step and the journey to still have a final observed criterion. Intermediate
evidence is kept in `steps[].checks`; a step failure is never cancelled by an
apparently correct final state.

### Flow destination distinct from the observation route

A flow binding can observe several routes under the same catalog key. In that
case `MomentHost.resolveRoute` chooses the destination from the declared
projection before navigating; the default is `projection['route']`. The callback
is pure: it only picks a route, without requests or actions. The engine passes
an unmodifiable copy of the projection, refuses external destinations and
validates before committing the new revision.

### Retrying service preparation without discarding the database

`up <name> --retry-preparation` explicitly repeats an interrupted service
preparation. It only accepts a ready base, a previous launch, the same Moment
and no journey in progress. Every service with `prepare` must declare
`prepareIdempotent: true`; the consumer is responsible for that idempotency. The
engine never repeats recipes or journey writes automatically.

## On-demand verification

### Refresh, resume and verify in one command

```sh
moments refresh --check
```

Use it with the local instance and the app running, after saving Dart. It
selects the active Moment and validates its criteria before asking the compiler
for work, starts a refresh or joins the automatic one already in flight, waits
for its confirmation and runs the criteria on that resume, without navigating
again.

The JSON in `.proofs/` holds compile/resume times and the check result;
`durationMs` measures the whole command. `stage` distinguishes `declaration`,
`compile`, `restore` and `check`; `refresh.mode` reports `started` or `joined`.
A compile/restart error is `failed`/exit 1 with no criteria run. A finished
compilation without a confirmed resume is `unavailable`/exit 2. A Moment
switch, saved-state or source change during the run, another compile attempt,
data preparation or a pending edit invalidate the run. There is no automatic
retry; the follow-up deadline is 80 s and reaching it does not cancel the
supervisor.

### Criteria and proofs

Criteria live inside the Moment in the Ash DSL, next to the situation they
describe:

```elixir
check(:draft_restored, kind: :restored, field: :modal, equals: "rating")
check(:review_not_published,
  kind: :backend_equals, field: :published, equals: false, match: :transactionId)
```

Run `moments sync` after changing the DSL. `restored` compares the whole saved
projection with the state the Dart adapter reports after resuming; the optional
field also requires the declared value. `backend_equals` checks an observed
field and requires the entity identity to match the restored situation.

| Result | Exit | Meaning |
| --- | --- | --- |
| `passed` | 0 | Every declared criterion was observed and met. |
| `failed` | 1 | A valid observation diverged from the expectation. |
| `unavailable` | 2 | Criteria, session/response or backend are missing; or code/state changed during the read. |

Unavailability wins in the aggregate result; individual results stay in the
report. An old Flutter revision is never enough to pass. The restore wait is
12 s.

Each run writes a unique JSON in the app's `moments/.proofs/`, ignored by Git.
The report records criteria, results, times and hashes of the manifest and the
watched Dart files, plus the commit when available. `code.dart` includes the
local library inventory and the Pub resolution identity; the runtime must
confirm the same applied digest before and after the proof. Draft text and
credentials are not copied; the projection is represented by a hash and the
names of diverging fields. Files are created with mode 0600. Deleting `.proofs/`
does not affect code, criteria or session.

This verifies the state declared by the adapter and a point observation of the
backend; it does not prove pixels, all widget memory or every domain
transition.

## Parallel suite: `moments suite`

```sh
moments suite --project <app>                          # browser: 4 workers, profile artifact (JS)
moments suite --headless --project <app>               # widget runtime (flutter_tester)
moments suite --wasm --project <app>                   # browser with the app in wasm
moments suite --affected [--base REV] --project <app>  # only the Moments affected since REV
moments suite <name> <name> --workers 2 --json         # selection and structured output
moments up <name> --backend-only --project <app>       # backend kept open between suites (optional)
```

Without an open backend, the suite starts a temporary `up --backend-only` and
stops it at the end; with one open, it reuses it. Before starting, it waits for
the supervisor to settle (backend compiled, no pending edits).

`--affected` uses the `moments affected` plan. In a monorepo, the plan ignores
changes that belong to another project of the checkout (a folder with its own
manifest: `pubspec.yaml`, `mix.exs`, `package.json`, `*.csproj`…) that the app
does not reach. Reachable are the app folder, the local Dart packages in
`package_config.json` and the roots in `moments/sources.json`. Repository-level
files without an owner still widen to the whole catalog, as do changes to shared
packages. Since the framework may live outside the app's Git, the suite keeps a
fingerprint of its sources after every green run; if it changed, the whole
catalog runs.

The suite runs several Moments at once against the backend of an open `up`.
Each worker has its own bridge and goes through `checkMoment`: recipes,
gestures, criteria, code identity and proofs land in `.proofs/`. Data is not isolated between workers beyond the unique fixtures
each recipe creates. A failing journey keeps its ownership for inspection; in the suite, the worker releases it explicitly (`ownershipRecovered` in
the result) because the effects stay in disposable fixtures. If ownership stays
active, the worker retires instead of guessing.

**Browser (default).** A `flutter build web --profile` artifact, keyed by the
resolved Dart sources and the defines (no code change, no rebuild), is served as
an immutable file. A headless Chromium owned by the run gives each worker an
isolated context. For each Moment, the previous tab closes and the site data
(cookies, storage, IndexedDB, caches, service workers) is cleared and
**verified empty**; if anything remains, the Moment fails instead of running
contaminated. `--debug-build` switches to the debug artifact (with asserts).
Moments run in debug and profile builds; release never contains them
(`momentsBuild` in live_ui).

**Wasm (`--wasm`).** The same artifact in `--profile --wasm`, served with
COOP/COEP so the wasm renderer can use threads. The summary records the renderer
observed in the first tab (`renderer.wasm`).

**Headless (`--headless`).** The app runs in `flutter_tester` (the Dart VM with
the Flutter framework, no browser and no GPU). A single `flutter test -j N`
compiles the app once; each worker is a long-lived test that fetches its bridge
envelope from the supervisor and, for each Moment, unmounts the app, resets
in-memory plugins and mounts it again through the app's own bootstrap. The app's
fonts are loaded. The app declares the harness in `config().headless`
(`{file, function}`), for example `test/moments/headless.dart` with
`runHeadlessMoments` from `package:live_ui/headless.dart`. An unhandled exception
ends the worker: the Moment fails with the exception attached and the worker is
reopened. A worker that stops keeping its control long poll for 3 s is also
considered dead and reopened. This is evidence of the widget runtime (layout,
hit testing, gestures, HTTP and app state), not of the web renderer. Moments
that only exist on one platform declare `platforms([:web])` in the DSL and show
up as not applicable on the headless track.

`up --backend-only` neither compiles nor serves Flutter; it applies backend edits
on its own when no journey is in progress. The suite uses the app's `webPort`
when free; with the dev Flutter open, it uses `suitePort`, which the backend must
accept in CORS.

Measured on 16 cores, apps with 14 and 11 Moments, backend already open,
artifact cached:

| Track | App A (14) | App B (11) | Peak memory (PSS) |
| --- | --- | --- | --- |
| Serial journeys in the dev sandbox | ~70 s + reopens | — | dev Flutter ~2.3 GB |
| Browser, 1 worker | 50 s | — | 0.85 GB |
| Browser JS, 4 workers, 1 Chromium | 33–36 s | 21 s | 1.6–1.8 GB |
| Browser wasm, 4 workers | 26–27 s | — | 1.65 GB |
| Headless, 4 workers | 18 s | 9.2 s (2 web-only) | 1.6 GB |

The full headless suite without an open backend (starting and stopping a
temporary one) took 23 s end to end. More browsers per worker cost memory with
no gain (software rasterisation saturates the CPU first). Each headless worker
uses ~350–430 MB (RSS). A new profile build takes ~31 s; wasm ~54 s; headless
startup ~12 s uncached, ~3 s cached.

## Recipes in Elixir: `Moments.RecipeSet`

An app's recipes live in sets that share helpers and the observation; each
recipe's body returns the launch:

```elixir
defmodule MyApp.Moments.Operators do
  use Moments.RecipeSet, observe: :observe

  recipe :operator_signed_in, "An operator signed in to the points screen." do
    launch("/points", operator(), point_inputs())
  end

  def observe(launch, projection), do: ...
end
```

The hyphenated name (`operator-signed-in`) is what `backend(:operator_signed_in)`
references on the Moment; `MyApp.Moments.recipes/0` joins the sets'
`__recipes__/0` for `Moments.Recipes`. A recipe can have its own `observe:`; the
body reads `context` when it needs it. The `Moments.Recipe` behaviour (one module
per recipe) is still accepted.

### Backend recipes and bases chosen by the DSL

A Moment declares `backend :recipe_name`; the manifest references the adapter the
app registered (`prepare` + `inspect`). The engine never needs to recognise a
screen's name. `moments inspect --json` shows the reference in
`moment.backend.recipe` and the recipe used by the observation in
`backend.recipe`.

Opening waits for preparation before changing the UI; on failure it keeps the
previous Moment. During preparation, the watcher pauses and the engine refuses
concurrent captures and openings. Unknown recipes are refused before the
adapter is called. `check` opens the projection with `prepare: false`, so
verification never prepares data. Inspection and refresh with check do not run
recipes either. `--fresh` is a UI state choice, not a domain reset.

`prepare(instance)` may return `{launch}`. The engine verifies the instance after
preparation, and the supervisor writes the private reference with an atomic
replace. A failure before that write keeps the previous reference; it does not
promise rollback of API writes. A saved identity that is missing or a changed
state fails explicitly, without recreating data to make a check pass.

Moments may declare a shared `base :name`. Each recipe gets a `backend.base`
dependency in the manifest. The app registers the base's preparation in
`BackendRecipes(bases: ...)`; the engine resolves the base before the specific recipe,
persists `baseRecipe` and reuses the reference on later `open`s and restarts.
There is no DAG: an instance has one base. Invalid references, unregistered
bases and an attempt to use another base in the same instance fail before
preparing data. An interrupted initial preparation keeps its checkpoint and
needs an explicit reset. A specific recipe that fails keeps the ready base.

## Compact context for agents

`moments inspect --json` returns `view: "active-moment"` by default:

- the active Moment, its description and saved state;
- the last UI observation, its age and revision match; if it differs from the
  saved state, the observed projection is included too;
- the watched files declared **for the active screen**, relative to `project`,
  and the Ash source with file and line in `sources.ash`;
- the criteria declared for that situation, always with `executed: false`;
- the backend observation limited to the fields and identities those criteria
  use;
- the supervisor's phase and pending work.

When the observed state matches the saved one, `matchesSaved: true` avoids
repeating the projection. That does not claim Flutter is currently present:
`liveness: "not-probed"`, age and revision match stay explicit. A declaration
without criteria returns `criteria.status: "none"`; a missing or incompatible
declaration returns `unavailable` and never borrows another screen's files.
Inspection produces no approval proof.

For the full catalog, editing properties and the complete observation:

```sh
moments inspect --full --json
```

If the manifest changes during the query, the compact output returns
unavailable. `sources.declaration` points to the generated manifest;
`sources.ash` points to the original declaration, using the annotation Spark
exports; sources are never inferred from names. The Ash source includes the
absolute `file` in the local checkout, `line`, `module` and `status`: `current`
means the file's SHA-256 matches the export; `stale` means the source changed
and the line may have moved. Run `moments sync` before trusting that line.

On one screen, the compact view cut the serialized JSON from 3,988 to 1,846 bytes
(53.7% less) and the files from 10 to 2, keeping all three criteria. That is a
single local measurement, not a token measurement or a guarantee for other
screens.

## The warm editing loop

```sh
# With the instance running: navigates and waits for the screen to confirm, no recompilation.
# Without an instance: prepares the environment and asks the default browser to open the route.
moments open checkout-open

# Save a Dart file: the launcher reloads or restarts and resumes the same screen.
moments status

# Local screen state and Flutter's last report (no database query):
moments inspect
```

Every edit goes through Dart source and the refresh below; there is no separate
preview layer to fold back into code.

`open` keeps the screen's saved state (filters and vertical offset, for
example). It creates a new revision, drives the existing instance to the route
and only succeeds after the screen reports ready. `commandToObservedMs` includes
the request and the CLI's wait; `openToObservedMs` measures from the bridge
accepting the move to the post-frame report.

The Moments transport and its binding are generic; the contract
`moments/manifest.json` is generated from the app's Ash declaration. The
projection lives in `moments/.backend/ui-session.json`, separate from
credentials. The binding waits for data and layout before applying scroll;
positions beyond the available content are clamped. Captures use a 120 ms
debounce and revisions to reject writes from old runtimes. The last
unconfirmed gesture can be lost if the process dies within that window.

Hot restart re-authenticates with the local account, loads current data through
the API and restores the projection. The same applies when the browser is closed
and reopened or the bridge restarts. The Moment's name does not undo domain
actions: a cancelled booking stays cancelled.

### Ash declaration → manifest → Flutter

The extension lives in `framework/ash/moments`. One declaration holds each
Moment's route, allowed properties, watched sources and initial values.

```sh
# After editing the Elixir declaration; not after every visual change:
moments sync
moments list
moments open checkout-confirmed
```

`sync` uses Docker/Elixir with an image pinned by digest, dependencies pinned in
`mix.lock` and a local cache ignored by Git. It does not require Elixir on the
host. The generated `moments/manifest.json` is versionable, holds no bootstrap
account and is enough for the warm loop without the compiler's Docker/Elixir.

Several Moments can share **the same instance and records** with different
initial UI (all filters vs. confirmed only, for example). Opening any Moment
resumes its last saved projection; on first open, it applies the recipe's
values. Each name keeps an independent projection.

Changing only recipes/descriptions in the manifest is picked up by the open
bridge. Changing the property contract or the watched sources needs a launcher
restart. New properties need support in the Flutter binding; the DSL does not
generate widgets.

### Save Dart → refresh → resume

The launcher watches the app's Dart libraries, the local (`path`) packages
resolved by Pub and the extra files in the Ash contract's `watch` list. A change
groups nearby saves for 100 ms and asks for a reload or restart through the
[official Flutter machine protocol](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/doc/daemon.md).
It is not an SDK fork: the launcher drives `flutter run --machine` with its own
pipes.

```sh
# Starts with automatic refresh of the local Dart libraries:
moments up checkout-confirmed
# Shows compilation, error or confirmation of the new screen, with timings:
moments status
# Requests a refresh by hand; returns the acceptance, not the confirmation:
moments refresh
# Disables automatic watching at start:
moments up checkout-confirmed --no-watch
```

The `ready` phase only appears after Flutter succeeded and a **new client** sent a
projection. The previous screen's observation is not proof of resume. The API
and Postgres stay alive. A compile error is shown in `status` and in the
terminal; the supervisor does not keep retrying without another change. Edits
during a compilation stay pending and are grouped for the next one. A Flutter
operation over 60 s requires stopping and starting the launcher.

File events under each local package's `lib/` wake the content check at once;
the content hash still decides whether anything changed. The watcher also checks
every 150 ms, which covers the other watched files, atomic replacements and
platforms that drop events. It caches hashes by file metadata; every proof
forces a full reread. New Dart files
in local libraries are picked up without editing `watch`. Changing manifests or
resolution needs `flutter pub get` and a launcher restart. It does not watch
hosted/SDK package bodies, assets, native code or credentials.

### Switching Moments without losing your place

The session keeps one projection per name plus the active name:

```sh
moments open checkout-open
# Pick filters and scroll; the confirmed capture is saved under this name.
moments open checkout-confirmed
# Work somewhere else on the screen.
moments open checkout-open
# Back to checkout-open's previous filters and scroll.

moments list                     # the active bridge's Moments, with saved/active
moments open checkout-open --fresh   # restart only the chosen UI projection
```

States survive hot restarts and launcher restarts. They are UI states over **the
same local database**, not independent copies of the data: cancelling a booking
affects every Moment that shows it. A late capture of the previous situation is
rejected by its revision. Resumed projections are validated against the current
contract, and names removed from the catalog cannot be opened just because they
are still stored.

## Web restart frame pause

Before `app.restart`, the supervisor asks for a pause through the authenticated
`/moments/changes` channel. The runtime confirms on `/moments/restart-ack` with
the instance and attempt identity. Only then does the restart proceed. Without a
confirmation within 2.5 s, the attempt fails without restarting the app.

The pause temporarily swaps `PlatformDispatcher.onBeginFrame/onDrawFrame` for
empty callbacks. Do not use `null`: the SchedulerBinding reinstalls them when
another frame is requested. The new runtime starts with the normal callbacks; on
failure the supervisor asks the previous one to resume. A 90 s lease also
releases the pause if the supervisor disappears. It only uses public debug APIs.

## Latency diagnostics

`moments refresh --check --json` includes `refresh.prepareMs`, `compilerMs` and
`runtime` in the result and the disposable report. The runtime records monotonic
milestones (main, runApp, first frame, data ready and confirmation) and
intervals for preferences, authentication, bootstrap, query and restore. These
are optional diagnostics, never criteria or pass thresholds. They carry
enumerated names, numbers and tab visibility/focus; never draft text, URLs,
credentials or exception messages. Dart and the runner have different clocks
and intervals can overlap.

## Independent consumers and Ash sources outside Flutter

`sync --project <app>` can create the first manifest; `moments/backend.json` also
identifies the app root.

By default the declaration's source must live inside the app. For a sibling
backend, the app authorises only the folder it needs in `moments/sources.json`:

```json
{"version":1,"roots":[{"name":"server","path":"../server"}]}
```

Paths are relative to the app, not to the manifest. The receipt records, for
example, `server:lib/tasks.ex`, the source hash and the digest of this
configuration. Check and inspection resolve realpaths and refuse symlink
escapes; the exported declaration cannot grant itself this permission.

Apps read `MANA_API_URL`; the launcher provides `MANA_MOMENTS=true` and
`MANA_MOMENT_BOOTSTRAP=true`. `runSandbox` accepts `flutterDefines(instance)` for
app parameters. Bridge tokens stay in a private file and only connect in
debug/loopback.

## Execution target: web, Linux or Android

`moments up <name> --device linux` starts native Flutter through the same machine
protocol used for the web. `--device web-server` is the default. Stop the
instance before switching targets; two UIs never compete for one session.
`open`, `suite` and `refresh --check` keep the same names and
declarations. `status --json` exposes `target: {requested, connected}` and only
reports a connection after `app.started`. Full-stack receipts record `target`
with `source: flutter-daemon`; a missing, divergent or changed target prevents
approval.

The supervisor keeps its signal handlers during asynchronous cleanup: repeated
SIGINT/SIGTERM reuse the same shutdown instead of killing the cleanup. After an
abrupt death, old locks still require an ownership/process inspection before
removal; there is no automatic takeover because a file looks old.

### Android transport and lifecycle

`android_transport.dart` sets up native `adb reverse` forwards for an explicit
list of TCP ports. The adapter supplies the exact serial, a **private
per-run directory** and the API/bridge ports; the loopback URL can stay the same
in Flutter. It does not start emulators, install APKs, prepare databases or use
`--remove-all`/rebind.

`androidTransport(options).start()` records intent before each effect and holds a
private claim per serial in `~/.cache/mana/android-transports`, which excludes
other Mana runs even after a supervisor death. `close()` cleans its own
endpoints; `recoverAndroidTransport(directory)` refuses a live supervisor and
recovers an interrupted journal without repeating creation. An offline device
keeps the claim. A different target on the same endpoint is refused; a reboot
identified by boot ID releases the old claim without removing the new boot's
mappings.

The boundary is **default-safe with local cooperative ownership**. ADB offers no
atomic conditional removal nor an owner per forward: concurrent manual changes
or external replacement on the same endpoints cannot be told apart. Do not
modify the reverses or reboot the device during a Mana operation.

`up <moment> --device android:<exact-serial>` works on a Linux host with ADB. The
device must be online and dedicated to the run; the command neither creates nor
deletes emulators. Android ownership is published in lifecycle **version 3
before allocation**; web/Linux stay on version 2, and older readers refuse the
new version instead of stopping a run while ignoring resources. `moments down`
closes the transport on normal shutdown and recovers it after the launcher dies.

### Additive evolution of the saved presentation

When reopening with a changed declaration, the engine may fill in missing
restorable properties from the current recipe's defaults, as long as the route
is the same. Saved values win and stay validated. Unknown/removed properties,
invalid enums, incompatible types and route changes are still refused. The
engine infers no renames or domain migrations; `--fresh` is the explicit
intention to use the initial recipe.
