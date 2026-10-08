# Moments.Extension

An Ash/Spark extension, used through a Mix `path:` dependency. It declares named
situations, their route, the allowed UI projection and a reference to the
backend recipe. The compiler exports JSON; opening a moment in Flutter runs no
Elixir. It follows the official APIs for
[Ash extensions](https://ash.hexdocs.pm/writing-extensions.html) and
[Spark entities](https://spark.hexdocs.pm/Spark.Dsl.Entity.html).

```elixir
use Ash.Domain, extensions: [Moments.Extension]

moments do
  route "/traveler/reservations?debugSession=0"
  live_ui_prefix "reservations."
  field :filter, "all", values: ["all", "confirmed"]
  field :scrollOffset, 0, min: 0, max: 10_000_000

  moment :checkout_confirmed do
    description "Local booking, Confirmed filter."
    defaults filter: "confirmed"
  end
end
```

Names with `_` become `-` in the CLI. Each field has a string enum or a numeric
range. The export refuses defaults outside the contract, extra fields, colliding
names and external routes. It never serializes sessions, controllers or widget
memory. The app should only declare state that is appropriate for local
persistence; the DSL does not detect secrets from a field's content.

In the Mix project: `mix moments.export MyAppMoments ../manifest.json`.
From the app: `framework/moments/moments sync`.

## Local review of an action

In the Mix project, `mix moments.review MyApp.Resource action output.json`
compiles the project and produces a plan from `Ash.Resource.Info`. It does not
start the application, run the action, test criteria or approve the
architecture. Compilation still runs the project's normal macros and verifiers.
Stop the development supervisor before sharing its build directory with another
compilation.

For example, from the repository root:

```sh
framework/cli/mana mix <server> \
  moments.review MyApp.Task complete \
  ../app/moments/.proofs/architecture/task-complete.json
```

The report separates compiled facts, `default-safe` paths and `reviewed`
questions with status `pending`. It holds the data layer, authorizers,
transaction configuration, local/global hooks, notifiers and native AshOban
references to the action when that extension is installed. Hook options,
closures, input values and descriptions are not serialized. Project sources are
compared before/after compilation and planning; the hashes identify that slice
without certifying external dependencies or runtime behaviour.

The listed Moments are candidates from the resource's primary domain, with
`unverified` coverage. There is no compiled link yet between each gesture and the
action: the plan does not automatically pick a journey as proof of the action,
nor resolve callers, dynamic calls or jobs created in custom code. A resource
with a configured policy is still subject to review of `authorize?: false`,
direct Repo access and actor/tenant propagation. No property becomes
`guaranteed` just by appearing in this report.

The command is explicit and local; it is not part of the build, the launcher or
any global gate. Reports can live in `.proofs/` and be discarded.

## Associating journeys with the review plan

After producing the Ash plan, the CLI can associate existing reports without
compiling, connecting to the app, preparing data or repeating gestures:

```sh
framework/moments/moments review \
  --plan <app>/moments/.proofs/architecture/task-complete.json \
  --evidence <app>/moments/.proofs/<journey>.json --json
```

`--evidence` can be repeated up to 32 times. The result references the plan and
each report by SHA-256 and lists only the spans of the chosen resource/action,
with Moment, step, execution kind and span result. The report's criteria and
business values are not copied. Input files are left untouched. The CLI reads
regular JSON files, no symlinks, up to 8 MiB each.

This association is **historical**: it does not compare the current checkout
with the run's sources nor certify where an editable local report came from. A
failed journey may also have run the action; `span-finished` does not prove a
commit or success. Duplicate or inconsistent receipts are refused; identical
inputs count once. Missing or truncated capture stays explicit.

Every candidate in the plan is kept with `unverified` coverage; an observation
outside the domain also shows up, without inventing a static relation. No
review question is resolved and no Moment is excluded for not appearing in the
receipts. Use the observations to find and prioritise journeys to inspect or run
again.

## Actions observed during a journey

`Moments.ActionTrace` implements Ash's native tracer for `action`,
`bulk_create`, `bulk_update` and `bulk_destroy` spans. `Moments.ActionTrace.Plug`,
mounted on the endpoint in development only, opens a capture per HTTP request
identified by the gesture and returns a receipt in `x-mana-actions`.
`MomentActionTrace.attach(dio, api)` (live_ui) sends `x-mana-gesture` only to the
configured loopback HTTP origin, inside the gesture's async zone, and only when
the consumer enables `MANA_ACTION_TRACE` for that backend (`flutterDefines` in
`moments/backend.json`; the headless suite inherits it).

A version 3 receipt also carries `changes`: the records the request changed, as
a history reported them (`Mana.History` calls
`Moments.ActionTrace.annotate_change/1`) — resource, id, action, `done` or
`failed` and the field names, never values; up to 16 per request.
`moments check` prints each one as `changed:`. A local origin alone does not
imply tracing support: a local release may refuse these headers in CORS. The dev
sandbox declares the flag; actors using production artifacts keep it off.

`Moments.ActionTrace.Telemetry` registers the native bulk events under the
application's supervisor, before the endpoint. They cover paths where Ash does
not hand the global tracer to the outer span. The handler runs in the emitting
process; the supervised process only registers/unregisters handlers. A span
already observed by the tracer is not duplicated by the handler.

The tracer uses one ETS table per request; it never puts actions or queries
behind a global process. It keeps up to 16 events, marking truncation, and
destroys the table when the receipt closes. Jobs, work after the response,
requests outside the zone and paths without a tracer are not covered. Records
hold only resource, action, domain, span kind, the `authorize?` flag when given
and the reported end or error; never arguments, actor, tenant, tokens or error
messages.

The bridge only accepts receipts for gestures dispatched in that
runtime/revision while the journey's ownership is still active. It refuses extra
fields, duplicates and late receipts from another journey. The budget is 256
requests per journey. The checker saves the receipts under `actions` in the
existing report in `.proofs/`. Capture failure is unavailable evidence, never
permission to repeat the action.

`span-finished` means the span ended, not that each write succeeded or
committed; `authorization_requested: true` does not prove every policy. Even with
an approved journey, the coverage of each effect/criterion stays
`not-established`. These receipts are not cryptographic attestation nor a
complete inventory of effects.

The consumer's HTTP/CORS/tracer integration is enabled by build configuration in
`dev` only; the Flutter helper depends on `kDebugMode`. The production
configuration does not install this plug or tracer.

Version 2 receipts add the inclusive duration of spans and of the request in
microseconds. The `Moments.ActionTrace.Telemetry` child can receive a
`repo_event` (for example `[:my_app, :repo, :query]`) to aggregate
Ecto events in the existing context. A single ETS tuple per request keeps the
count and the total/query/queue/decode time sums; no query, parameter or SQL
metadata is stored. A missing event is `not-observed`. `moments profile` uses
this data on the existing journey; its sums may overlap and are neither CPU time
nor an additive breakdown of the total.

Each exported Moment also carries `source`: the declaration's file, line, module
and source SHA-256. The location comes from the entity's Spark annotation. The
path is relative to the manifest's folder, so it carries neither Docker's
`/workspace` nor the checkout's absolute path. `build`/`build_many` accept
`source_root:` for exporters; the Mix task uses the JSON file's folder.

`moments inspect` resolves that source in the local checkout. If the file
changed after the export, it marks the reference `stale` and recommends
`moments sync`; a missing file or an old manifest without metadata returns
`unavailable`.

`framework/cli/mana mix <project> <mix arguments>` uses Linux + Docker, runs with
the user's UID/GID and mounts the host's CA bundle read-only. The Elixir
1.18.4/OTP 27 image is pinned by digest. The cache in `framework/ash/.toolchain`,
`deps/` and `_build/` stays out of Git; the app's `mix.lock` pins dependencies.
The helper never mounts the Docker socket inside the container.

Focused verification:

```sh
framework/cli/mana mix framework/ash/moments test
(cd framework/moments && dart test)
```

The manifest is the development bridge, not an Ash backend in production. Real
data, authors and recipes belong to the app; the
[Moments launcher](../../moments/README.md) integrates the consumer's services.

## Backend recipe declared per Moment

```elixir
moment :booking_notifications do
  description "The local account's inbox with booking notifications."
  backend :notification_inbox
  check :notifications_unread, kind: :backend_equals,
    field: :allUnread, equals: true, match: :deliveryIds
end
```

`backend` exports `{"recipe":"notification-inbox"}` outside the UI projection.
The reference resolves to an adapter the app registers with the launcher (in
Dart, `BackendRecipes`):

```dart
recipes: {
  'notification-inbox': RecipeAdapter(prepare: prepareNotifications, inspect: inspectNotifications),
  'review-draft': RecipeAdapter(prepare: prepareReview, inspect: inspectReview),
},
```

`prepare(instance)` ensures the prerequisites; `inspect(instance)` reads the
current state. Recipes should be idempotent and keep existing actions.
Credentials and database access come from the runner's local instance, never
from the manifest. The DSL accepts an identifier, not a path, command or
serialized function. Preparation returns nothing when the local reference does
not need updating, or `{launch}` with the new reference. The runner checks the
instance's ownership again and writes `launch` atomically before opening the UI.

The launcher validates the registration before starting the instance. After
preparing the local base, it runs the selected recipe before starting Flutter.
With the app open, `open` also waits for preparation before changing the
revision/route. An error keeps the previous UI and draft; there is no automatic
retry. The watcher pauses during this operation. If the declaration changes
during preparation, the opening is refused. There is no generic rollback of the
adapter's writes: recipes with writes must handle their own atomicity.

`inspect`, `check` and `refresh --check` never call `prepare`: a verification
cannot repair the data it is meant to evaluate. `--fresh` only affects the UI
projection; it is not a request to renew or clean domain data.

## Shared base declared in Ash

Each screen contract can declare the base its recipes depend on:

```elixir
moments do
  route "/traveler/reviews?debugSession=0"
  base :traveler_workspace
  # fields/watch/checks stay in the screen contract
  moment :review_draft do
    description "Completed stay, with the draft kept"
    backend :review_draft
  end
end
```

The manifest exports `backend: {recipe: "review-draft", base: "traveler-workspace"}`.
The app registers a `BaseAdapter(prepare: ...)` under `bases` and the specific `RecipeAdapter` under `recipes`. The
base returns `{launch}`; the engine persists its identity and private reference
before running the specific recipe.

There is one base per instance, with no dependency graph or parallel execution.
Once ready, it is reused across Moments and restarts; `open` and `--fresh` never
redo it. Switching to a different base is refused. `inspect` reports the base and
observes the data; `check` does not prepare it.

The initial preparation writes `phase: seeding` before its writes. An
interruption at that stage requires an explicit reset of the disposable
instance, since the base has no transactional resume. If the base finished and
the specific recipe failed, the next opening reuses the base and repeats only the
specific recipe.

## Moments protocol ancestry

`from(:checkout)` inside a `moment` keeps the parent in the exported catalog.
References across domains are resolved in `build_many`; missing parents and
cycles fail. A Moment without a parent is a root. `base` stays a shared
preparation recipe and takes no part in ancestry. With relations, the export
format is 3, Moments protocol 0.1, profile `mana-ash-flutter`; without relations,
1/2 stays valid. See the [contract and capabilities](../../moments/README.md#protocol-profile).

In a production artifact, the tracer, handler and Plug are inactive and the HTTP/CORS
headers are absent. The library modules may remain in the artifact; this excludes the
consumer's development path, not arbitrary Elixir code inside the same VM.

## A Moment can be navigable only

Checks are optional in the Ash contract, even when there are steps. The same
situation can serve editing, inspection and verification; add criteria when
there is something to verify, without duplicating its recipe or ancestry. The
exporter validates targets and `until` references, but requiring a final
criterion belongs to the `run` operation, not to authoring the map. `navigate`
captures the UI without verifying final criteria; declared `until` conditions
still govern its steps.
