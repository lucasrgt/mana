# Moments — development runner

Moments is the runner of named, navigable situations for Mana apps (Ash backend +
Flutter client). It opens a situation by name, keeps it alive while you edit,
verifies its declared criteria, forks it into independent copies and selects
the Moments a change affects. The protocol it implements is in
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
Discovery distinguishes `executionProfiles.launcher` from
`executionProfiles.materialized`: parents and forks are supported by
`open --isolated`/`fork` with an adapter and captured roots; the plain commands
never flatten children into roots.

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

The materializer walks `from`, runs each ancestor once and captures its layers
before opening independent copies. The public path is `open --isolated` or
`fork`, with an explicit local adapter and a browser host. Plain opening and
the launcher's `run` keep refusing children: they cannot treat them as
independent roots.

Capturing the database also captures durable queues. The adapter must control
producers before starting a copy; blocking only the external transport does not
stop attempts from being consumed or state from changing. Booting Oban in manual mode
in the copy, a parent Moment can queue a job and a child can run the AshOban
worker explicitly, keeping the attempt when restored; further children can add
real loopback SMTP with private capture. Restoring a mailbox does not send email
again. Criteria are observed by the same `check --session`, without repeating
the transition. The engine does not intercept arbitrary effects or guarantee
network isolation.

The `private-json` layer captures opaque JSON objects of up to 1 MiB in private
files outside the Flutter bridge. It requires the adapter to confirm writers
are stopped, verifies the snapshot's identity and digest before copying, and
refuses symlinks, public files and unknown content during cleanup. Writes above
the limit are refused before replacing the state. `recover --run` and
`recover --session` recognise this layer without importing the app's adapter.
Restoring locally captured messages does not undo sends to an external provider
and does not promise exactly-once delivery.

`open --fresh` resets presentation; `up --fresh` runs the app's preparation;
`reset --discard-data` discards the stopped database. None of them is the
specification's `reset` to the origin. Navigation stays distinct from
verification: the map and the export accept Moments without criteria; `run` is
specific to verified journeys.

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
moments check notifications --json
moments run notification-read       # prepare, tap the UI and check in Ash
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

### Interfaces with shared storage

The internal `WebActor.start` host optionally accepts `surfaces`, a map of 2–8
IDs allocated by `allocateBrowserBoundary` to `{bridgeUrl, bridgeToken}`. All
use the same bundle, web origin and API; each keeps its own bridge, runtime
claim, observations and gesture channel. Bootstrap version 2 selects only the
interface named by `momentsActor` and confirms the same ID in Dart. A missing,
duplicate or unknown selector is refused, with no default bridge.

This is a routing boundary, not security isolation between interfaces on the
same origin: they share storage and run trusted local code. The IDs are not
credentials. It is not `fork`, does not copy the database and does not change
the Moments' `from` ancestry. The dynamic path is debug/loopback only; regular
and release builds never fetch the bootstrap.

The host provider has an optional `reveal(id)`. The preview host uses it to
bring its existing iframe into view before gestures/observations, avoiding
off-screen frame throttling. It neither navigates nor recreates the interface.
Revealing does not prove rendering: the journey still needs receipts and
observations.

### Composing steps and checkpoints without redeclaring the domain

The engine in `lib/src/composition.dart`, used by `moments compose`, takes a
version 1 plan with `stages`. Each stage names `id`, `surface`, `moment` and
`kind`:

```json
{
  "version": 1,
  "stages": [
    {"id": "sign-in", "surface": "a", "moment": "tasks-login", "kind": "steps", "steps": ["email", "password", "sign_in"]},
    {"id": "check", "surface": "a", "moment": "tasks-login", "kind": "checkpoint"}
  ]
}
```

`steps` selects names in declaration order and keeps their `until`.
`checkpoint` observes all of the Moment's final criteria or an explicit
selection in `checks`. It runs no recipe or gesture. Restore criteria are
refused here: they need the runner that holds the restore receipt. The plan
accepts no alternative targets, values, predicates or ancestry; `from` stays in
the catalog.

`compileComposition(plan, manifest)` validates the whole plan before connecting
interfaces. `executeComposition({plan, manifest, connect, report, beforeStage,
afterStage})` uses the existing gesture executor and evaluator. The adapter's
`connect({surface, moment})` supplies `request` and may supply
`validateInspection`. Preparation, ownership/leases, private inputs and closing
belong to the adapter. Hooks receive only the stage ID and allow explicit local
coordination, such as arming a failure; they are not declarative criteria and
do not allow re-execution after an uncertain result.

Receipts distinguish `declared-step-postconditions`, `all-final-criteria` and
`selected-final-criteria`, with time, duration and runtime identity. `passed`
approves the run of the selection, historically, without claiming every
referenced Moment is still valid at the end. The engine pins client/revision
per interface, refuses aliases for the same client, stops after a failure and
never repeats gestures.

Within this API, selection without redefinition and interruption without replay
are `guaranteed` by the compiler/executor and the protocol's negative tests.
Using the existing executor and evaluator is `default-safe`; custom adapters
still control transport and inspection. Ownership, freshness of backend
observations and hook semantics require adapter review (`reviewed`).

### Running a composition from the CLI

```sh
moments compose --plan moments/compositions/shared-session-late-401.json \
  --profile session-tabs-0c724e40 \
  --browser-socket /private/path/browser.sock \
  --browser-provider <host-id> --json
```

The browser host must be connected and explicitly authorise the profile's web
origin. The CLI validates the whole plan before running the local program
`moments/adapters.dart`, which calls `runCli(args, adapters: ProjectAdapters(...))`.
The `composition` adapter receives the context, is synchronous and creates no
resources; the returned `CompositionProfile` supplies `recovery`,
`prepare(signal:)`, `connect`, `cleanup(passed:)` and, optionally,
`beforeStage`, `afterStage` and `verify`. `verify` may add profile-specific
observations; it does not replace or change checkpoint approval.
`cleanup({passed})` must confirm closing even after partial preparation.
Adapter exceptions are not copied to the public output because they may contain
private inputs.

The session uses the same lock/marker and ownership format as
`open --isolated`/`fork`. `recovery` declares supported processes, containers
and roots up front, and may declare up to eight `browsers` directories with
records created by `allocateBrowserBoundary`. The adapter may not create
resources before returning their handles/cleanup.

`plan.json`, `session.json` and `composition-report.json` under
`moments/.proofs/materializations/<uuid>/` keep the selection, ownership and
results. SIGINT/SIGTERM interrupt the sequence and wait for cleanup; effects
already sent are not reverted. An unconfirmed shutdown keeps the marker and
returns 2. After the supervisor stops, use `moments recover --session <dir>`
with the matching browser host if interfaces are still open. Recovery does not
import the adapter, relaunch services or repeat recipes/gestures.

Exits: 0 selection passed and resources closed; 1 a criterion failed and
resources closed; 2 execution or shutdown unavailable/uncertain.

### Public preparation and recovery without replay

```sh
moments prepare --profile session-tabs-<new-id> --json
moments recover --preparation moments/.proofs/release/session-tabs-<id> --json
```

`prepare` runs the `preparation` adapter from `moments/adapters.dart`, a
function `({project, profile, onProgress})`. The adapter controls build,
migrations, provisioning and confirmations; the CLI forwards progress and the
result. There is no implicit resumption of sign-up or migration. Preparing a
profile does not verify its journeys nor approve a production release.

The default preparer records a private journal **before any effect** through
`await registerPreparation(...)`: processes and containers owned by the
attempt, plus receipts of the services to stop or keep. Paths are relative to
the proof directory; symlinks and external paths are refused. Recovery lives in
`lib/src/managed.dart` and never runs the app's adapter, SQL, migrations or
recipes.

`recover --preparation` requires the original supervisor to be dead. It first
stops the recorded creator processes and build containers, then checks the
services' name, owner label and Docker ID. The ID is persisted before a service
is stopped; a replacement after recovery starts prevents another stop.
Databases declared as kept are neither stopped nor removed. A failed inspection
does not prove absence.

The journal becomes `attention` when shutdown stays uncertain and `closed` on
success; later calls touch nothing. The registration holds the consumer's
`flock` until `await ownership.close()` or `await ownership.attention()`. A
second preparation and the managed lifecycle operations are refused while the
lock is held. This property is `guaranteed` within the managed paths that use
this registration/lock; manual commands and adapters that ignore it are outside
that boundary.

### Latency profile of the same journey

`moments profile <name> --json` runs the declared journey once, with the same
preparation, gestures and criteria as `run`. Writes that are part of the
journey happen normally; there is no automatic repetition to collect samples.
It uses the local launcher, without `--session`, materialized branches or
concurrent load.

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

### Managed opening and forking

```sh
moments open task-edit --isolated --browser-socket /private/path/browser.sock --browser-provider 2
moments fork task-edit --copies 2 --browser-socket /private/path/browser.sock --browser-provider 2 --json
```

The project supplies `moments/adapters.dart`, trusted local code whose
`materialization` adapter is synchronous. The returned `MaterializationProfile`
has `prepare`, `cleanup`, `codeIdentity` and the `engine` (`layers`, `runtime`,
`recipes`, `scope`). It also records `recovery`: local `processes`/`containers`
directories and `roots` with name/type (`postgres` or `flutter-actor`), plus
the cluster identity when needed. Registration happens before `prepare` and may
not contain credentials, external paths or callbacks.

`fork` accepts 1 to 8 copies, two by default. The session keeps the actors
alive until SIGINT/SIGTERM; `--json` emits progress JSONL, `ready` with
URLs/IDs and `closed` after cleanup. These receipts are not approval of
business criteria. Declared transitions may write to the copies. Roots are
discarded only after actor shutdown is confirmed. Failures keep an `attention`
record in `.proofs/materializations/<id>/session.json`.

To verify **the copy that is already open**, use another terminal:

```sh
moments check session-expired --session /path/to/app/moments/.proofs/materializations/<id> --project /path/to/app --json
moments check session-authenticated --session /path/to/session --actor <uuid-from-ready> --project /path/to/app --json
```

`--actor` is required when more than one copy is ready. The command returns 0
when criteria pass, 1 on failure and 2 when unavailable; it keeps the session
open in all cases. A Moment without final criteria is still useful for editing,
but its check returns 2.

The managed check validates project, live session, ownership marker, run,
catalog, actor and bridge before calling `checkMoment({materialized: true})`.
It imports no adapter, compiles nothing and reapplies no recipe or gesture. The
transport only allows state, inspection and status GETs; it refuses redirects,
non-loopback addresses and responses identifying another actor.
`guaranteed` boundary: on this public entry point and the supported local
runtime, verification cannot dispatch mutations, preparation or gestures
through the transport. Custom consumer observation code is still trusted and
under review.

To recover the whole set after the supervisor dies:

```sh
moments recover --session /path/to/project/moments/.proofs/materializations/<id> --browser-socket /private/path/browser.sock --browser-provider 2 --json
```

The session path validates workspace, dead supervisor and inventory before
recovering build processes, containers, runs and, last, roots. It does not
import the current adapter or repeat recipes. A kernel lock and a durable
marker prevent another materialization and the default `up`, `down` and `reset`
paths in the same consumer. After a crash, the marker requires explicit
recovery before the project is reused.

An opening without an answer keeps its resources until it is reconciled. An
empty inventory alone does not prove absence. The provider's optional `find`
contract may return `{matches: [], settled: true}` **only** when every opening
for that nonce has finished and no late call can open a tab afterwards.

With a dev launcher, it must be stopped first. Preparation compiles a
current Ash release and Flutter debug artifact, copies the database and
authenticates inside the copy. Actors use the same fixed artifact: there is no
hot reload in this mode; code editing stays on the `up`/`refresh` launcher.

#### Postgres credentials per branch

The driver accepts `opts.runtimeAccess: {schemas: ['public'], connectionLimit: 12}`.
When declared, materialization produces a v3 handle and a private `access.json`
with a random, exclusive login/password. Without the option, the v2 contract
keeps a NOLOGIN owner for existing coordinators; that does not allow using it as
an application credential. `postgres.runtimeAccess({handle, dir, opts})`
requires v3, a valid cluster/database/role identity and the matching private
file. The adapter builds its own `DATABASE_URL` and should refuse missing
credentials, with no administrative fallback.

The v3 role is not a superuser, does not create databases/roles, does not
replicate, does not bypass RLS and has no explicit membership. Public CONNECT is
revoked on copies. DML and sequence privileges in the declared schemas are
granted to `pg_database_owner`, so copied grants do not depend on the parent's
ephemeral role (see
[PostgreSQL 16 predefined roles](https://www.postgresql.org/docs/16/predefined-roles.html)).
Snapshots stay sealed and their owners cannot log in.

- `guaranteed` in the driver: refuses a divergent credential/owner identity and
  never accepts a v2 handle as v3 runtime access.
- `default-safe`: own roles, native privileges and the normal Ash/Ecto pool. A
  custom adapter with coordinator access can deliberately leave this path; it is
  not a sandbox against hostile local code.
- `reviewed`: public ACLs, SECURITY DEFINER functions of the origin and external
  integrations need review in the consumer.

`dart run tool/prove_postgres_access.dart <instance.json> <database>` exercises
real credentials, local writes, access/escalation refusals, inheritance after
the parent is discarded and recovery of a lost response while enabling login.

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

`run` records ownership in `moments/.backend/.journey.json` before preparing
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
releases the instance without undoing or repeating actions. Only a new explicit
`run` prepares and runs again.

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
widening. Each selected entry says `operation: run` if it has steps, or `check`
otherwise. Run that operation in the indicated project with
`moments run <name> --project <app>` or `moments check <name> --project <app>`.

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

### Journeys: `run`

`run` requires steps declared in the Ash DSL. It prepares and opens the
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
coherent evidence is `unavailable`. That wait belongs to `run`; `check` and
`refresh --check` observe a coherent situation without waiting for false
criteria to become true.

Flows across several screens can keep a binding in the development shell, with
a stable entry route and an observed/restorable current destination. Session
identity and phase are observations only (`restore: false`); restoring the
destination never authenticates the user and the normal guards stay active.

During `run`, the instance has one exclusive owner. Other commands that
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

### Verify without compiling

```sh
moments check review-draft
```

The command resumes the saved situation, waits for a new Flutter confirmation
and queries the isolated backend. It neither compiles nor prepares data.
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
gestures, criteria, code identity and proofs in `.proofs/` are the same as
`moments run`. Data is not isolated between workers beyond the unique fixtures
each recipe creates. A failing journey keeps its ownership for inspection, as in
`run`; in the suite, the worker releases it explicitly (`ownershipRecovered` in
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
| Serial `run` in the dev sandbox | ~70 s + reopens | — | dev Flutter ~2.3 GB |
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

### Renewing data without rebuilding the instance

When a time-limited situation expired, or you want a fresh initial record:

```sh
moments renew checkout-confirmed
moments renew                       # check the last operation, without creating another record
moments inspect checkout-confirmed
```

`renew <name>` requires the backend launcher running and Flutter ready. The
recipe reuses the existing accounts and records and, through the normal local
APIs, creates the next record the situation needs. It does not change the clock
or revive the expired record; earlier records stay in the database. The
supervisor keeps the Postgres, API and Flutter processes, atomically saves the
new reference, reapplies the requested name's UI recipe and asks Flutter for a
hot restart. The command waits up to 90 s for the screen to confirm. There is no
automatic retry; a failure before the new reference is saved keeps the previous
one. The APIs do not form a single transaction, so an interruption may leave
partial records in the local database.

| Command | Effect |
|---|---|
| `open <name>` | Resumes the saved UI projection. |
| `open <name> --fresh` | Reapplies only the UI recipe. |
| `refresh` | Refreshes the app and waits for its resume in the supervisor. |
| `renew <name>` | Adds a new record for the situation and opens the UI recipe. |
| `reset --discard-data` with the launcher stopped | Removes the instance's database and projections; the next `up` rebuilds everything. |

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
`check`, `run`, `open` and `refresh --check` keep the same names and
declarations. `status --json` exposes `target: {requested, connected}` and only
reports a connection after `app.started`. Full-stack receipts record `target`
with `source: flutter-daemon`; a missing, divergent or changed target prevents
approval.

The supervisor keeps its signal handlers during asynchronous cleanup: repeated
SIGINT/SIGTERM reuse the same shutdown instead of killing the cleanup. After an
abrupt death, old locks still require an ownership/process inspection before
removal; there is no automatic takeover because a file looks old.

### Additive evolution of the saved presentation

When reopening with a changed declaration, the engine may fill in missing
restorable properties from the current recipe's defaults, as long as the route
is the same. Saved values win and stay validated. Unknown/removed properties,
invalid enums, incompatible types and route changes are still refused. The
engine infers no renames or domain migrations; `--fresh` is the explicit
intention to use the initial recipe.

## Isolated copies: layers and materialization

### Postgres layer

`postgres_layer.dart` implements capture/materialize/dispose for a Docker
cluster with proven Moments ownership.

- `sourceHandle` adopts an existing database for reading/capture only; `dispose`
  refuses that handle. New copies (v2) get random names, an OID, a comment and an
  owner of their own without login, checked against the exact container on every
  operation. The owner and its mark are created atomically before the database;
  the database is born sealed and only a complete branch enables connections.
- `capture` uses `CREATE DATABASE ... TEMPLATE ...` with no active connections.
  The snapshot has connections disabled. It never runs `pg_terminate_backend`,
  forces sessions closed or calls `DROP ... FORCE`.
- `materialize` creates an independent database from the sealed snapshot. The
  destination has an exclusive intent persisted before the effect; a second
  process cannot replace the first creation.
- `dispose`/`forget` remove only identified copies; active connections, a
  changed OID, owner or comment stop the operation. `recover({dir, opts})`
  reconciles an interrupted v2 intent without recreating the database or
  repeating recipes. A lost DROP response allows another cleanup without
  repeating CREATE.

```sh
dart run framework/moments/tool/prove_postgres_fork.dart \
  <app>/moments/.backend/instance.json <database> \
  <app>/moments/.proofs/postgres-forks
```

The proof copies the app's real tables, including tokens and Oban, adds a
row to one copy only and creates two branches of the same snapshot, comparing
fingerprints of every public table before/after. Run it with the app and its
workers stopped. Databases share a cluster and an administrator: data
independence is not a security boundary against a client with superuser
credentials.

### Layered materialization coordinator

`materializer.dart` consumes the catalog exported by Ash; `from` is the only
ancestry relation. `build(name)` materializes the parent's snapshot, starts the
runtime, runs the transition registered in `backend.recipe`, stops the runtime
and captures the layers. The parent's snapshot is reused by other continuations
in the same run; the recipe is not redone for each branch. `open` hands over a
copy with a live runtime, and `fork` several copies of the same point.

Each integration supplies layers, explicitly captured roots, allocate/start/stop
callbacks, transition recipes, code identity and scope. The whole catalog is
validated; code or declaration changes during the transition prevent publishing
the snapshot as current. A failed transition is never repeated automatically.
Flutter gesture journeys require `runtime.executeJourney`; without that executor
they are refused rather than silently ignored.

`runtime.allocate(world)` returns a synchronous handle without starting
processes. The coordinator records the handle before calling
`runtime.start(handle, world)`. Every started resource must belong to the
handle, even when start fails partially. `runtime.stop(handle)` must be
idempotent and only finish after every component stopped.

`runtime.executeJourney(world, {navigation: true, ...})` uses
`checkMoment({materialized: true, manifestFile, navigation: true, ...})` to walk
the gestures without reapplying recipes. Final criteria are optional and not
evaluated in that operation. The coordinator requires a `captured`
`materialized-navigation` receipt tied to the right instance, parent,
destination and manifest, with the lease released. The receipt lives in
`instance/journey.json` with `verification: not-performed` or
`step-criteria-only`; capturing a navigable state does not approve business
criteria.

Durable events in `events.jsonl` carry run/instance/snapshot/transition,
sequence, instant and scope. `run.started` pins the protocol, manifest hash and
code identity. `snapshot.ready` means the declared layers were captured, not that
criteria were verified. Adapter exceptions never go into events.

### Projecting a run onto the map

`moments graph --events <events.jsonl> --json --project <app>` combines the
declared map with a materialization's events. It is an offline read: it loads no
adapters, touches no database, runs no recipe and defines no new dependency.
Each edge references the transitions actually started/completed/failed.
Captured snapshots and the last recorded instance state stay separate from
criteria (`verification: not-recorded`). The reader rejects broken sequences,
mixed runs, relations incompatible with `from`, events without their
predecessors and an incomplete last record. The read limit is 16 MiB.

### Flutter actor layer

`flutter_actor.dart` captures only `ui-session.json` (route and declared
restorable properties) and `actor-state.json` (explicit private slots). Each copy
has its own directory and identity. Snapshots have content hashes; changes are
refused before the next instance is created. The driver refuses symlinks,
existing destinations, disposing the origin and handles of another copy.
Private files are written with mode 0600.

The integration must supply `assertStopped`: capture/dispose cannot happen with
the actor alive. On the web, stopping `flutter run` does not stop the tab's
JavaScript; the actor's owner must also close the tab before stopping
bridge/API and capturing.

`Bridge.start(privateStores: ['session'], ...)` enables a local authenticated
channel for the slot; it is absent by default. `MomentPrivateStore` in Dart only
connects in a development launch, and `SessionStore.callbacks` adapts
read/write to the normal Ash session. The saved value is still validated by the
API; the bridge issues no tokens, ignores no revocation and never logs in again
to hide a rejected session. The channel has one active client **per declared
slot**. Private slots never enter the visual projection or execution events.

### Owned containers and processes

`allocateOwnedContainer` (in the `mana` package) records ownership in `container.json` before any Docker
call. Allocation is exclusive. `create` creates a stopped container; `start`
starts only the captured ID after checking its name and ownership label. A
creation or start failure never allows repeating the operation. `stop` checks the
identity, stops by ID, observes the stop and only then removes the container. If
the `create` response is lost, recovery finds the container by name and label and
pins its ID to disk before removing it. Recovery refuses a live supervisor (PID,
process start and boot). Divergent labels/IDs are refused before stop/remove.
This is not isolation against hostile code with access to the same Docker daemon.

`owned_process.dart` provides allocation, start, inspection, stop and recovery
for an actor process. On Linux, the run belongs to a transient **user systemd**
unit with `KillMode=control-group` and no automatic restart. Ownership includes
a random name, description and InvocationID, checked before asking for a stop.
The cgroup covers detached children that a periodic PPID scan could miss. The
`process.json` record exists before the launcher; a worker inside the unit waits
for the coordinator to confirm and persist the InvocationID before starting the
command. Requires Linux, cgroup v2 and a user systemd; there is no equivalent
adapter for macOS/Windows yet.

### Coordinated recovery of an interrupted run

`recoverMaterialization({directory, layers, runtime})`: creating a run saves
`run.json` with the coordinator identity, manifest/code, adapter types and scope
before allocating layers. Recovery refuses a live coordinator, validates the
whole inventory and requires adapters passed explicitly by the caller,
compatible with those types. It never imports the manifest or loads recipes to
clean up.

The runtime implements `recover({dir, instanceId})`, stops its resources and
returns `{status: 'stopped', instanceId}`. Every runtime must confirm the stop
before any layer is discarded. Each driver implements `recover({dir, opts,
pending})` and confirms `{status: 'disposed'}`. A failure keeps `recovery.json`
in `attention`; the next call resumes through idempotent inspection. Roots given
to the run are not part of its disposable inventory.

**Guarantee limit:** the coordinator guarantees reference validation and callback
order; adapters must verify the real stop and ownership of each resource. A
custom callback that invents a receipt is not proof of a stop.

### Browser boundary of the local actor

`browser.dart` records the intent to open a tab before exposing its URL. Each URL
gets an ownership identifier; the host associates provider and tab ID with the
opening. Closing requires a current inspection of the tab, a URL match (allowing a
route fragment change) and confirmation of absence after closing. A divergent
tab, a missing provider or an opening without identity keep cleanup pending.
There is no search by title and no closing of all browser tabs.

The `ash-flutter-local` recovery adapter confirms the browser boundary, stops the
Flutter process and removes the API container. The provider is an explicit host
dependency with `id`, `inspect(tabId)` and `close(tabId)`; inspection returns
`{id, status: 'present', url}` or `{id, status: 'absent'}`.

```sh
framework/moments/moments recover --run /path/app/moments/.../runs/UUID \
  --project /path/app --browser-socket /tmp/private-host/browser.sock \
  --browser-provider 2 --json
```

`recover` without `--run` keeps its meaning: release the development instance's
journey after inspecting its effects. With `--run`, it stops and discards the
interrupted run's copies; the origin, external roots and the original journal
are kept. The CLI supports the `ash-flutter-local` profile, with `postgres` and
`flutter-actor` layers, and refuses runs from another project, directories
outside `moments/` and symlinked paths.

The CLI connects to a private Unix socket of the same user. The host serves
`inspect`/`close` for bound tabs plus `open` and `resolve`. Opening requires one
of the explicit `openOrigins` (`http://127.0.0.1:<port>`) and the `momentsActor`
nonce. The host persists the intent before calling the browser, records the
returned ID and reuses that record after a restart. A lost response is reconciled
by an exact search for the bound URL; zero or several matches keep the situation
uncertain. Another tab is never opened to resolve that uncertainty. An origin
that is not authorised gets a terminal cancellation per nonce.

In restricted hosts, `moments host browser <dir>` keeps the socket in the CLI and
forwards requests through private files to the editor's browser API. The
directory belongs to the user with mode 0700; `bindings.json` declares
`provider` and `tabs: [{id, url}]`. Each answer is correlated by UUID; a missing
answer keeps the data held. This boundary assumes trusted local adapters and
processes; it is not isolation against malicious code running as the same user.

### One Flutter debug bundle for several actors

`MomentRuntime.initialize()` loads per-instance configuration only in Flutter web
debug with `MANA_MOMENTS=true` and `MANA_RUNTIME_BOOTSTRAP=true`. The app resolves
its API with `MomentRuntime.apiUrl(declaredValue)` before creating clients.
`web_actor.dart` serves a compiled Flutter artifact and the local
`/__moments_runtime` endpoint. Each origin supplies its own endpoints/token,
with no cache and no CORS for other origins; only loopback is accepted. The token
never goes into the URL or the shared bundle. Actors keep their own HTTP
processes, bridge, session and database; only the compiled files are shared.
It is a fixed artifact for navigation/testing/auditing: it has no hot reload.

`FlutterActorServices` brings the API, bridge and Flutter/web process up and
down for an actor. It takes a backend adapter (`allocate/start/stop`), a frontend
(`flutter-run` or `shared-debug-artifact`) and `assertBrowserClosed`. The handle
is registered before start; a failed start is never repeated. Stopping waits for
a pending start and only stops services after the host confirmed the tab is
closed. `FlutterActorRuntime` composes the services, the browser boundary
and the journey executor; the host opens the tab and the runtime waits for the
Moment's first observation.

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

### Materialized Android actors

`FlutterActorRuntime` accepts `frontend.mode: 'flutter-android'` with an
explicit `device: 'android:<serial>'` and `applicationId`. The runtime identity is
`ash-flutter-android`, with no fake browser provider. The same executor walks the
declared steps and criteria; the Flutter daemon confirms the connected device.
The CLI offers `open <moment> --isolated --device android:<serial>` and
`check <moment> --session <dir>`. One device holds one open actor at a time.

With `frontend.runtimeBootstrap: true`, the debug defines are constants; API,
bridge and actor capability travel in Flutter's native `--route`, inside a
reserved `__mana_moments` envelope. `MomentRuntime.initialize()` consumes and
validates it before the HTTP clients, refusing services outside
`http://127.0.0.1:<port>`, credentials in URLs, invalid tokens and repeated or
extra query parameters. In go_router, declare
`overridePlatformDefaultLocation: MomentRuntime.nativeBootstrap` together with the
restored `initialLocation`.

For immutable materialized scenarios, the adapter can also supply
`frontend.applicationBinary: '/private/path/app-debug.apk'`, which requires
`runtimeBootstrap: true`. The launcher uses Flutter's
`--no-hot --no-pub --use-application-binary`. `apkanalyzer` must be on the PATH:
before any effect, the runtime checks package and debug flag, pins the SHA-256 on
the first open and refuses changes between actors.

Before launching Flutter, `AndroidActor` takes ownership of the transport and
records the intent to open the package. It refuses an app already running and
devices with more than one Android user. Before capturing state, the launcher's
contained process must be gone, `am force-stop --user 0` stops the explicit
package and `ps` confirms the main and `package:*` processes are absent. Only then
is the transport released. It neither clears data nor uninstalls the APK.
Boundary: **default-safe** with a dedicated device, user 0 and coordination
between Mana runs.

### Artifact fingerprints

The artifact fingerprint keeps the `sha256-tree-v1` format.
`artifactFingerprint(directory)` always reads every byte. For repeated queries in
the same run, `ArtifactFingerprint(directory).snapshot()` walks the whole
tree and reuses file hashes only while device/inode, size, permissions and
ctime/mtime in nanoseconds match. Additions, removals, inode swaps and changes
with a restored mtime invalidate the identity. Use `snapshot({fresh: true})` to
reread every byte explicitly. This is **default-safe** on a local filesystem with
trusted metadata; it is not an integrity attestation against a hostile host.
