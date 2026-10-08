---
name: mana
description: The Mana framework as one system. Use before writing any backend, Flutter or test code in a Mana project: find the existing capability (mana capabilities <topic>), the feature that owns the files (mana features which), and the Moments that prove it, instead of re-deriving or reimplementing them.
---

<!-- Generated from framework/catalog.toml by `mana capabilities skill`. Edit the catalog. -->

# Mana — one framework

Mana is not a set of loose libraries. Every piece below is part of one system: the product declares intent once in Ash, and Mana derives the API, the Dart client, the Flutter halves, the Moments and the verification. Reimplementing a piece by hand is a defect even when it works.

## Before you write code

1. `framework/cli/mana capabilities <topic>` — does Mana already do this? Use it.
2. `framework/cli/mana features which <path>` — which feature owns the file; `mana features show <feature>` lists its files and Moments.
3. Change the Ash resource first; regenerate the client (`mana client generate`); then the Flutter half.
4. Prove it with the feature's Moments (`framework/moments/moments check|run <name>`); read the AVP verdict, never only the exit code.
5. `dart analyze` at the package root (Mana lints) and `framework/cli/mana doctor` before finishing.

## Coordinates — shared addresses

### Feature map (`features`)

The shared feature:<name> address: which files, verbs, Moments and sensors belong to each product feature, and where the trio has gaps.

- **Use:** mana features which <path> before editing; mana features show <name> for its files and Moments; mana features changed to review a diff by feature; mana features coverage [name] for verbs no Moment exercises, features with Moments but no verbs and verbs without a declared feature (verb feature: "name"). Declare new files in features.toml. mana features remove <name> [--apply] plans (and applies) removing a feature: deletes files only it owns, keeps shared ones, lists its Moments and the verbs still naming it.
- **Instead of:** guessing a feature's files by grep; reviewing a PR file by file
- **Enforced by:** mana doctor and mana features check fail on unowned files
- **Docs:** `framework/cli/README.md`

### Moments (`moments`)

Named, reproducible situations of an app (moment:<app>/<name>): open, check, run and fork them instead of navigating by hand.

- **Use:** framework/moments/moments list|open|check|run|suite|affected --project apps/<app>. Declare Moments in Ash (backend/lib/<app>/moments) and run moments sync.
- **Instead of:** one-off UI test suites; manual navigation to reach a state; screenshots as proof
- **Docs:** `framework/moments/README.md`

### Reasoning memory (`memory`)

Why a decision was taken and what was already tried, kept with the code instead of in loose notes: each note is addressed by coordinate (feature:, verb:, moment:, entity:), carries the receipt that backed it (a sensors verdict) and the hash of what it describes, reads stale once that code moved, and a verb's because: cites it (mana doctor refuses a missing note).

- **Use:** Before changing a rule: framework/cli/mana note show verb:booking.cancel (or feature:bookings, moment:hosts:host-cancel). After deciding or trying: mana note add --about feature:<name> --about verb:<type.verb> --why "..." [--outcome tried|failed|kept] --receipt last. In the DSL: verb :cancel, because: "<note id>". Notes live in notebook/*.jsonl (versioned; never edited by hand).
- **Instead of:** decisions lost between sessions; markdown notes nobody finds; retrying an approach that already failed; a rule nobody dares remove because nobody knows why it exists
- **Docs:** `framework/cli/lib/src/notebook.dart`

### Intent by example (`intent`)

An ask becomes situations a person judges and criteria that freeze before implementation: intents/<id>.toml names the Moments and sensors that decide it; approval freezes the criteria (edits afterwards are refused) and records the decision in the notebook; check runs them into one AVP verdict.

- **Use:** Agent proposes intents/<id>.toml (ask, feature, [[situation]] moment + expect, [[criterion]] id + moment = "app:name" or sensor = "<id>"); the person reviews with framework/cli/mana intent show <id> and approves with mana intent approve <id> --by <name>; done means mana intent check <id> passes. Never edit an approved intent — propose a new one.
- **Instead of:** acceptance criteria in chat that drift; "done" decided by the implementer; specs written as prose nobody checks
- **Docs:** `framework/cli/lib/src/intents.dart`

## Core

### API contract and generated client (`contracts`)

Ash resources export OpenAPI; Mana generates the Dart client and blocks breaking changes with oasdiff.

- **Use:** Change the Ash resource, then run mana client generate. Never edit the generated client by hand.
- **Instead of:** hand-written HTTP calls; hand-written fromJson models; editing packages/api
- **Docs:** `framework/contracts/README.md`

### Release runtime (`runtime`)

Explicit release configuration, edge, metrics and readiness for Ash/Phoenix.

- **Use:** Dependency {:mana_runtime, path: ...}; Mana.Runtime.load! in runtime.exs.
- **Instead of:** ad-hoc release config
- **Docs:** `framework/ash/runtime/README.md`

### Agent launcher and setup (`agents`)

mana.toml declares products, setup tasks and agent skills; mana setup, doctor and agent run them.

- **Use:** framework/cli/mana setup | doctor | agent claude|codex.
- **Instead of:** per-developer agent configuration; README setup steps
- **Docs:** `framework/cli/README.md`

### Live entities and deadlines (`entities`)

A resource's changes are announced on entity:<type>:<id> and entity:<type>:for:<user> (only the id; clients read again through the API), and its deadlines are durable Oban jobs scheduled by the change that enters the watched state, run only if the state still holds.

- **Use:** Server: extensions: [Mana.Entity]; entity do broadcast MyAppWeb.Endpoint; audience [:owner_id]; deadline :expire, action: :expire, when: expr(status == :open), after: {30, :minute} end; mount once channel "entity:*", Mana.Entity.Channel, assigns: %{otp_app: :my_app} (serves every live resource). A repair a deadline missed belongs in Mana.Reconcile with apply. Flutter (mana_live): once at the app root ManaLiveScope(changes: PhoenixEntityChanges.api(baseUrl, token: session.accessToken), me: <signed-in user id listenable>, child: ...) — put it in the app's account scope; then the widget that shows the records declares what it follows — LiveEntity.of(MunicipalityEntity.entity, onChange: viewModel.load, child: screen) follows the signed-in user's records (the generated XEntity.entity), LiveEntity.of(entity, id: recordId, ...) one record, LiveEntity.view(BookingViews.reservationCard, onChange: ..., child: ...) a view declared live: true. It subscribes while mounted and cancels when it leaves; widgets on the same topic share one channel; after a dropped connection comes back every followed screen reads again once (EntityTopics.missed), so no timer polls. No subscription code in view models. A resource may declare watchers: {Mod, :fun}(user) for who follows every record of it on entity:<type>:all (an operator queue); Flutter LiveEntity.of(XEntity.entity, all: true). Deadline conditions are asked of the stored row, so they may use relationships (exists(charges, ...)). Moments: Mana.Entity.observe(record) (topics, deadlines that hold) and fake(resource, id, deadline) (a deadline comes due now).
- **Instead of:** a cron that scans a table for expired rows; polling a screen for changes; ad-hoc PubSub broadcasts per action; subscribe/unsubscribe code in view models
- **Docs:** `framework/ash/core/lib/mana/entity.ex`

### Verbs (`verbs`)

Each domain action declared once with when it is offered, its risk, inverse, idempotency and feature. Every record carries the verbs it offers the actor now (state + Ash policies); the server refuses the action when `when` does not hold (with the domain error named by unavailable:, idempotent verbs let through), so the state rule is written once; the client gets typed constants; Flutter shows, confirms and undoes from them.

- **Use:** Server: extensions: [Mana.Verbs]; verbs do verb :cancel, when: expr(status != :closed and (host_id == ^actor(:id) or starts_at > datetime_add(now(), 24, :hour))), unavailable: :not_cancellable, risk: :money, inverse: :reopen end (when sees ^actor, so per-person rules live there too) — the verb's action is an update/destroy on the record (not a generic action taking an id), and reads load :verbs. What is created or done with no record of its own is a collection verb on the resource it creates: verb :request, collection: true, from: {MyApp.Service, :service_id}, when: expr(public == true) is offered by the parent (its verbs list "booking.request") and refused on create when the parent does not hold; without from, when: {Mod, :fun}(actor) and Mana.Verbs.available/2 (Flutter account.available, an AvailableVerbs) say what the person may start (offers yes until the first answer and keeps the last answer when a refresh fails; the app refreshes it after the session or profile change and after any write, since a write can open or close an offer); a parent's verbs also list its children ("charge.checkout" on a booking), and a write that moves the record can ask fields[type]=verbs to get the next offer in its reply; a generic action is guarded by its collection verb automatically; unavailable: {Mod, :fun} answers the precise refusal. Steps of a Mana.Flow declared as verbs are offered as the flow reaches them. Declare confirm: true when a riskless verb still deserves a second look (the client asks; money and destructive verbs always ask). Client: BookingVerbs.cancel (generated). Flutter (mana_command): VerbGate(verb:, offered: record.verbs, run:, confirm:, builder:) for a control of its own; runVerb(context, verb, offered:, run: / collect: + runWith:, confirm:) for action-bar items, menus and dialogs a view model drives — collect gathers the verb's inputs from a form (checked against its VerbInput rules; the form stands for the confirmation) and runWith receives them; entry.offers(BookingVerbs.x) to show or hide. Verification: Mana.Verbs.archetypes/1 names the AVP archetypes a verb claims (authorization; lifecycle-gate when its when is enforced); an app keeps one AVP test that discovers every declared verb, fails on a verb with no fixture, and runs those archetypes through the real endpoint. Declare external: "stripe" (or "email", "sms") on a verb whose action reaches an outside system: checkpoints refuse it, History.replay refuses it (or skips it with external: :skip), and it can never queue offline. Each JSON:API operation carries x-mana-verb with the verbs it performs. A change to one record runs one at a time and re-checks when: on the stored row (concurrent accepts: one lands). Flutter: VerbForm(XVerbs.y) builds the form from the verb's inputs (controllers, set for non-text inputs, validate, unique via taken, submit placing server refusals on fields).
- **Instead of:** switch over a status in the app to decide if a button shows; duplicating 'can do X' rules in the app; confirm dialogs decided per screen
- **Docs:** `framework/ash/core/lib/mana/verbs.ex`

### Views (`views`)

What each screen reads from a resource, declared once on the resource: its read loads exactly those calculations, the contract carries the view, and the generated client gives the sparse fieldset that asks the server for nothing more.

- **Use:** Server: extensions: [Mana.Views]; views do view :reservation_card, fields: [:status, :verbs, ...], live: true, describe: "..." end; the read that serves it: prepare({Mana.Views.Load, view: :reservation_card}). Client: operations.listX(fields: BuiltMap(BookingViews.reservationCard.sparse)). Flutter: each view is also a typed class <Type><View>View (fields typed from the attributes model, .fields for the sparse request, .of(record)); read records through it.
- **Instead of:** a module attribute listing every calculation each read loads; screens fetching every attribute of a record; fields lists kept by hand in the app
- **Docs:** `framework/ash/core/lib/mana/views.ex`

### Primitives mechanism (`primitives`)

How a fullstack piece is built: a Spark extension on Ash resources that `use Mana.Primitive` with a contract key, a catalog id and Moments hooks; its contract lands on the resource schema and in info.x-mana-primitives, mana client generate writes its Dart half (refusing keys it has no writer for), and mana doctor checks it is catalogued.

- **Use:** Server: use Spark.Dsl.Extension, sections: [...]; use Mana.Primitive, contract: "x-mana-things", catalog: "things", moments: [:fake]; @impl Mana.Primitive def contract(resource). Client: a PrimitiveWriter in framework/cli/lib/src/primitives.dart and the types in framework/flutter/mana_primitives. Discovery: a [[capability]] here. Examples: Mana.Verbs, Mana.Views, Mana.Attachments. Moments hooks are public functions of those names (observe/capture/restore/fake); Mana.Primitive.hooks_implemented?/1 checks every declared one exists.
- **Instead of:** a new put_x step in the contract pipeline per feature; hand-written client constants mirroring server declarations; features nobody can find
- **Docs:** `framework/ash/core/lib/mana/primitive.ex`

### Agent over verbs (`agent-verbs`)

Agents act on the running app the way its screens do: open an entry (a view declared with entry:) and get its records with the verbs each offers now and their inputs; follow one of those verbs and get the record after. A verb not offered cannot be followed; follows are recorded in history as the agent's. Served over HTTP by Mana.Agent.Plug and to MCP clients by mana mcp.

- **Use:** Server: views do view :agenda_card, fields: [...], entry: :as_host end; forward "/agent", Mana.Agent.Plug, domains: [...] behind authentication. Agent: MANA_AGENT_TOKEN=<access token> framework/cli/mana mcp --api http://127.0.0.1:5318 --agent planner (tools entries, open, follow). In code: Mana.Agent.open/4, Mana.Agent.follow/7.
- **Instead of:** one MCP tool per endpoint; agents calling actions the screen would not offer; dumping whole tables into an agent's context
- **Docs:** `framework/ash/core/lib/mana/agent.ex`

### Feature health (`feature-health`)

Every JSON:API request labelled with the feature of the verb it reaches; requests, server errors, refusals and p95 per feature over the last minutes.

- **Use:** Start Mana.Feature in the supervision tree; plug Mana.Feature.Plug, otp_app: :my_app, prefix: "/api" before the router; Mana.Feature.report(minutes) for an operator panel.
- **Instead of:** error dashboards by endpoint; guessing which feature a slow route belongs to
- **Docs:** `framework/ash/core/lib/mana/feature.ex`

### New project and lab (`new-project`)

mana new writes a whole project around Mana (Ash backend, Flutter app, generated client, Moments, Mana as a pinned submodule); mana lab runs that backend against a Moments sandbox.

- **Use:** mana new <folder> [--mana-ref <release>] then moments suite --headless --project app; MANA_MOMENTS_INSTANCE=app/moments/.backend/instance.json mana lab prepare|serve|test|mix. Replace the starter Notes domain with yours and keep the wiring (OpenApi module, recipes, MomentHost/MomentViewBinding in the app).
- **Instead of:** copying an existing app to start a new one; hand-wiring Moments, contracts and the client in a fresh project; per-project scripts that point a backend at the sandbox database
- **Docs:** `framework/cli/README.md`

## Primitives

### Validation on both sides (`validation`)

Every verb's inputs reach the client with the rules its Ash action enforces (required, lengths, regex, ranges, one_of, uuid, dates, Mana.BR formats and uniqueness); a field checks them as the user types, and the server's refusal lands on the field it names.

- **Use:** Server: nothing new — constraints on the action's attributes and arguments are the rules. Client: BookingVerbs.counter.input('counter_note') gives a VerbInput; in Flutter (mana_command) TextFormField(validator: input.validator(message), keyboardType: input.keyboard, inputFormatters: input.formatters) and send input.value(text); on a refusal verbFieldErrors(response.data) maps codes to fields; a unique input (a single-attribute identity) gets uniqueValidator(input, taken) — debounced, the server still decides. Plain checks: input.check(value).
- **Instead of:** maxLength and regexes copied into widgets; hand-written CPF/CEP masks and validators; a server error shown in a banner instead of on its field
- **Docs:** `framework/ash/core/lib/mana/verbs.ex`

### Presentation forms (`forms`)

Forms declared in the Ash resource (Mana.Presentation.Extension) compiled to typed Flutter forms with presence, length and integer-range validation.

- **Use:** forms do form :name ... end in the resource; mana forms generate --server --resource --output.
- **Instead of:** hand-written create/update forms that duplicate Ash constraints
- **Docs:** `framework/ash/presentation/README.md`

### Brazilian identifiers (`mana-br`)

CPF, CNPJ, CEP, phone and plate: validated, canonical and masked the same on server and client. The schema carries format br-cpf | br-cnpj | br-cep | br-phone | br-plate.

- **Use:** Server: attribute type Mana.BR.Cpf (Cnpj, Cep, Phone, Plate). Flutter: import package:mana_br; BrFormat.cpf.formatter / .keyboard / .validator() / .display(), BR.isCpf, BR.maskCep.
- **Instead of:** CPF/CNPJ/CEP/phone/plate masks written in an app; check-digit validators in Dart; regular expressions for Brazilian documents
- **Enforced by:** mana_lints: mana_use_primitives (Dart) and mix mana.lint (Elixir)
- **Docs:** `framework/flutter/mana_br/README.md`

### Error catalog (`errors`)

Stable product error codes and 4xx status per refusal, declared in the Ash domain and exported as the ErrorCode enum.

- **Use:** errors do ... end in the domain (Mana.Domain); raise Domain.error(:name); clients map ErrorCode to copy.
- **Instead of:** matching error message strings in the app; ad-hoc error maps
- **Docs:** `framework/ash/core/README.md`

### Public access and rate limits (`access`)

Which actions are public and their rate limits, declared in the resource (Mana.Resource access) and enforced inside the action; Mana.Router derives the public routes.

- **Use:** access do public :action, rate_limit: ... end in the resource.
- **Instead of:** route-level auth exceptions; rate limiting in controllers or plugs
- **Docs:** `framework/ash/core/README.md`

### Privacy (LGPD export and erasure) (`privacy`)

Resources declare privacy; Mana.Privacy exports a person's rows through the declared projection and erases them.

- **Use:** privacy do ... end in each resource holding personal data. erase :detach keeps rows other records still name (a place a booking was at) and cuts them from the person through the resource's detach update action; erasing also drops the history of deleted records and forgets the person as the actor of the rest (actor_id cleared, via: "erased").
- **Instead of:** hand-written export or deletion jobs per table
- **Docs:** `framework/ash/core/lib/mana/privacy.ex`

### Retention (`retention`)

Rows past a declared age are deleted on a schedule (Mana.Retention.Worker under Oban).

- **Use:** retention do delete_after :expires_at, days: 30 end in the resource.
- **Instead of:** cron jobs that scan tables to delete old rows
- **Docs:** `framework/ash/core/README.md`

### Uploads, storage and attachments (`uploads`)

Files go straight to object storage through short-lived signed URLs; kinds declare accepted types, size and thumbnails; a resource declares which attributes hold files (Mana.Attachments), which checks ownership, reaches the contract and the client, and fakes a ready file for Moments.

- **Use:** Files resource: uploads do kind :photo, accept: :images, max_bytes: ..., thumbnail: 320 end (Mana.Uploads). Holder: extensions: [Mana.Attachments]; attachments do files MyApp.Asset; attach :cover_photo_id, kinds: [:photo] end; calculate :cover_url, :string, {Mana.Uploads.Url, attribute: :cover_photo_id}. Flutter: uploadAttachment(account, photo, PropertyAttachments.coverPhotoId) from the app's account package (rejects before uploading). Moments/tests: Mana.Attachments.fake(Property, :cover_photo_id, owner_id). An attachment of a list attribute carries max (the attribute's max_length constraint) to the client: XAttachments.extraPhotoIds.max. kind max_side:/quality: reach clients through x-mana-attachments so images are shrunk before upload. Flutter: AttachmentUploads (progress, retry of a failed file, max respected) and AttachmentField.
- **Instead of:** proxying file bytes through the API; storage keys used as URLs; hand-written signed-upload code; validate {Mana.Uploads.Attached, ...} repeated per action; picking AssetKind by hand at each upload; seeding a fake photo by hand in Moments
- **Docs:** `framework/ash/core/lib/mana/uploads.ex`

### Integrations (`integrations`)

Provider slots with an adapter per environment; production refuses to boot with a fake or unconfigured adapter.

- **Use:** use Mana.Integration, otp_app: ... for each provider (SMS, e-mail, payments).
- **Instead of:** calling a provider SDK directly from a resource; environment checks scattered in code
- **Docs:** `framework/ash/core/lib/mana/integration.ex`

### Webhooks (`webhooks`)

Provider webhooks received with the raw body intact so signatures are checked over the exact bytes.

- **Use:** Mount Mana.Webhook in the endpoint before Plug.Parsers.
- **Instead of:** re-encoding a parsed body to verify a signature
- **Docs:** `framework/ash/core/lib/mana/webhook.ex`

### Free-text search (`search`)

A read narrowed by a case-insensitive text over declared string fields, with LIKE wildcards escaped.

- **Use:** prepare({Mana.Search, fields: [:name, :city]}) in the read action.
- **Instead of:** hand-written ilike filters
- **Docs:** `framework/ash/core/lib/mana/search.ex`

### Enums and shapes (`enums-shapes`)

Closed value sets (use Mana.Enum) and named embedded objects (use Mana.Shape) published once in the API.

- **Use:** use Mana.Enum, values: [...]; use Mana.Shape on embedded resources.
- **Instead of:** string constants duplicated in the app; anonymous embedded schemas
- **Docs:** `framework/ash/core/README.md`

### Session (`session`)

Short sessions with rotating refresh over AshAuthentication (server) and AshSession in Flutter, which injects the Bearer only on the configured origin.

- **Use:** Server: framework/ash/session. Flutter: AshSession over the generated client's transport, ManaSecureStorage for persistence.
- **Instead of:** hand-written token storage and refresh; Authorization headers set per request
- **Docs:** `framework/flutter/ash_session/README.md`

### Paged reads (`pagination`)

OffsetPage<T> reads Ash offset pagination metadata (meta.page) with counts.

- **Use:** Flutter: OffsetPage from framework/flutter/ash_query.
- **Instead of:** parsing pagination metadata by hand
- **Docs:** `framework/flutter/ash_query/README.md`

### Commands (`commands`)

Stateful commands for view models (Query, RowAction, QuietAfterDispose, CommandBuilder, typed Refusal).

- **Use:** Flutter: package:mana_command in view models; CommandBuilder in views.
- **Instead of:** bool loading / error fields in view models; try/catch per button
- **Docs:** `framework/flutter/mana_command/lib/mana_command.dart`

### History (`history`)

Every create, update and destroy of a resource is recorded as it happens — who (user, system deadline or agent), which verb, inputs, before and after, failed attempts with their error code — in a log resource with its own retention; a record's history answers only to whoever may read the record.

- **Use:** Log: a resource with extensions: [Mana.History.Log, Mana.Resource]; history_log do subjects [MyApp.Booking] end; retention do delete_after :at, days: 730 end; route index :of, route: "/:subject_type/:subject_id". Subject: extensions: [Mana.History]; history do log MyApp.HistoryEntry; redact [:secret] end; verb ..., narrate: "cancelled the booking". Agent changes: pass context: %{mana_agent: "name"}. Replay: Mana.History.fixture(Log, "booking", id, %{user_id => "host"}) exports the entries with roles (commit it, e.g. backend/priv/moments/replays/*.json); Mana.History.replay(Booking, entries, actor: %{"host" => host, "traveler" => traveler}, params: fn action, params -> ... end) rebuilds a new record that ends where it ended — a Moment recipe built on it is hosts:host-replayed-counter. Flutter: ManaHistoryEntry.fromJson(attributes) and HistoryTimeline(entries:, entry:) from mana_command. Mana.History.note(resource, id, %{action:, via:, outcome:}) records what happened around a record (deliveries, webhooks; replay skips notes). Time travel: the log's :as_of action (route it) answers the record as it stood at a moment. A failure reported to error_reporter keeps the report id; telemetry [:mana, :history, :entry] and mix mana.history.export --since feed the warehouse. Flutter: HistoryView (Undo on the newest change whose inverse is offered; tap an entry for as-of).
- **Instead of:** audit tables written by hand in each action; activity feeds assembled from status columns; analytics events duplicated next to the change
- **Docs:** `framework/ash/core/lib/mana/history.ex`

### Declared recovery (`recovery`)

Each verb declares how it survives failure: retry: n resends transient failures, offline: :queue keeps it in a device queue that survives restarts (only idempotent verbs, never money — compile-time rules); screens never test connectivity; on the server, run_all undoes done steps through their inverse when a later one fails.

- **Use:** Server: verb :mark_read, idempotent: true, retry: 2, offline: :queue; Mana.Verbs.run_all([{record, :verb, params}, ...], actor) compensates. Flutter: deviceVerbRunner(slot:, verbs: NotificationVerbs.all, send:) from the app's account package (VerbRunner in mana_command) — run(verb, id) answers done/queued/failed, flush() on load, stateOf(verb, id) for the button. Every call is covered without wrapping it: the contract marks each operation with the verbs it performs (x-mana-verb), the client generates ManaOperations.all, and the account installs VerbPolicy (Dio), which resends a transient failure up to the verb's retry and keeps an offline: :queue call on the device (answered 202) until the API answers again. Mana.Reconcile escalate: config :mana_core, :reconcile_escalate, {Mod, :fun} receives every rule's report of each run (open an operator case on diverging, close it on converged).
- **Instead of:** if (connectivity) checks in screens; hand-written retry loops; a queued payment replayed twice; sagas coded per flow
- **Docs:** `framework/flutter/mana_command/lib/src/verb_runner.dart`

### Flows (`flows`)

A multi-step journey kept on the record (onboarding, checkout, KYC): the server moves a cursor through declared steps — refusing steps not reached, passing over skip_if steps, never moving back — so it resumes on any device; records expose flow progress, funnel/2 counts each step (of a query too, e.g. leaving test accounts out), and when a step stalls — counted from when the record entered it, its creation included — a durable job diagnoses it from the record's history — :bug (technical failures) or :abandoned (no attempt, or refused inputs then silence) — emits [:mana, :flow, :stuck] telemetry and calls on_stuck(record, step, diagnosis).

- **Use:** Server: extensions: [Mana.Flow]; flow do cursor :lifecycle_state; step :terms_pending, action: :advance_terms; step :address_pending, action: :save_address, skip_if: expr(...); done :complete; stuck_after {2, :day}; on_stuck {MyApp.Hosts.Actions, :remind_onboarding}; not_reached {MyApp.Hosts, :error, [:previous_step_incomplete]}; queue :maintenance end; load :flow in the read. Mana.Flow.funnel(Resource) or Mana.Flow.funnel(Ash.Query.filter(Resource, ...)); Mana.History.note(Resource, id, %{action: :step_action, outcome: :failed, error: "code"}) records a refusal that happened elsewhere (a wrong code, an email that did not leave) as an attempt at the step, so diagnose/2 sees it. Client: HostFlow.flow (ManaFlow) — stepOf/indexOf/progress of the record's cursor. stuck_after may be {Mod, :fun} returning {amount, unit} when the step is entered (a knob). Flutter: FlowScreens<S>(XFlow.flow, [(screen, step or null)]) lays the app's screens over the journey (resume(cursor, passed:), progress, previous/next); FlowBuilder draws the current one with its position.
- **Instead of:** a Step change per action that moves an enum by hand; progress computed in the app; a cron that looks for abandoned signups
- **Docs:** `framework/ash/core/lib/mana/flow.ex`

### Notifications (`notifications`)

The notices a resource sends are declared next to the actions that cause them — recipient (attribute or :counterpart from Mana.Entity's audience, never the actor), template, category, channels, deep link — and go out after the action succeeds through the app's sender; clients follow the declared link and group preferences by category.

- **Use:** Server: extensions: [Mana.Notifications]; notifications do sender MyApp.Notifications.Sender; notify :accept, to: :traveler_id, template: "reservation.confirmed", category: :reservations, opens: "/traveler/reservations?booking=:id", channels: [:inbox, :email]; notify :cancel, to: :counterpart, template: ... end; payload: [:city, :rejection_reason] copies attributes into the notice for the template's {city} text; when the recipient or the data is not on the record, to: {Mod, :fun} and payload: {Mod, :fun} compute them from it. Sender: @behaviour Mana.Notifications.Sender; deliver(%{to:, template:, channels:, payload:, record:}) → :ok | {:error, _}. Delivery rules in the section: preferences {Mod, :allows?} (user, category, channel; inbox always kept), quiet_hours {Mod, :until} (outbound channels held as a job), group_within {10, :minute} (repeats about the same record go to the inbox only), and per notice fallback: true (try channels in order until one delivers). Flutter: ManaNotification.of(BookingNotifications.all, templateKey)?.link(payload). Notices go out after the action commits; each delivery joins the record's history (sent, failed, held). A sender may answer {:failed, [{channel, reason}]}. Flutter: ManaNotices.all (generated) gives a delivery's category and link; InboxController (filter, unread, optimistic read); notificationChoices + NotificationPreferences for category x channel switches.
- **Instead of:** notify! calls inside each action; who-gets-it rules duplicated per action; notification taps routed by guessing from the template; opt-out checks inside each mail; repeated emails about the same record; hand-rolled push-then-email fallbacks
- **Docs:** `framework/ash/core/lib/mana/notifications.ex`

### Knobs (`knobs`)

Values that change while the app runs, often by someone who is not a developer: declared and typed in code with a default (a value or an MFA, so configuration stays the fallback), only the current value stored (with history of who changed it), gradual rollout to listed actors or a percent, verbs gated server-side by a knob, and stale knobs listed for removal.

- **Use:** Server: defmodule MyApp.Knobs do use Mana.Knobs, store: MyApp.KnobValue; knob :platform_checkout_enabled, :boolean, default: {MyApp.Payments, :configured, [:platform_checkout_enabled]}, feature: "payments" end; the store resource uses extensions: [Mana.Knobs.Store, Mana.History]; config :mana_core, :knobs, MyApp.Knobs. Read MyApp.Knobs.get(:name) / enabled?(:name, actor); set(:name, value | %{"value", "actors", "percent"}, by); unset(:name); stale(). Verb: verb :apply_coupon, knob: :coupons_enabled. Expose GET/POST routes for operators when they need to change knobs from an admin screen. Ask first: does a non-developer need to change it while the app runs? If not, it is configuration. Number knobs take min: and max:, and set refuses values outside them. knob :reviews_enabled, :boolean, enables: "reviews" turns every verb of that feature (and its sub-features) on and off on the server and in what is offered.
- **Instead of:** redeploying to flip a setting; hiding a button while the server still accepts the action; flags nobody remembers to remove
- **Docs:** `framework/ash/core/lib/mana/knobs.ex`

## Verification

### AVP verdict on every check (`moments-verdict`)

Every Moment check and journey report carries an AVP verdict: pass, fail, not-applicable or unresolved per criterion, outcome and acceptanceScore. Unavailable evidence is never green.

- **Use:** Read report.verdict (or the 'Veredito AVP' line) instead of inferring success from exit codes or logs.
- **Instead of:** ad-hoc success reports; trusting a passing build as acceptance
- **Docs:** `framework/moments/lib/src/verdict.dart`

### Mana lints (`lints`)

Analyzer rules: design-system only, feature boundaries, library independence, use primitives.

- **Use:** Enabled in each app's analysis_options.yaml; run dart analyze at the package root (flutter analyze does not show plugins). mix mana.lint reports Elixir code that reimplements a primitive (hand-made broadcasts, dated Oban jobs, imperative notices, Brazilian identifiers); mana:allow <why> on the line or the one above keeps one.
- **Instead of:** review comments about raw Material widgets, cross-feature imports or reimplemented primitives
- **Docs:** `framework/flutter/mana_lints/README.md`

### Sensors (`sensors`)

Declared verification signals (sensors.toml) with coverage (paths, feature:, moment:), cost and what they prove. mana sense --changed picks the ones a change needs and runs them cheapest first, stopping at the first failure; the result is an AVP verdict.

- **Use:** framework/cli/mana sense --changed [--budget 5m] after an edit (or --dry-run to see the plan); mana sense list; mana sense run <id>; mana sense learn measures the kept runs into sensors.lock (median and p95 duration, fail and flaky rate, catches per minute, files its failures came with) and planning then uses the measured cost. Declare a sensor for every new test entry point.
- **Instead of:** running the whole suite after every edit; guessing which tests cover a change; reading CI YAML to find the checks
- **Docs:** `framework/cli/README.md`

### Agent checkpoints (`checkpoint`)

An agent's plan of verb steps runs first as a dry run inside a transaction that is always rolled back — reporting the history it would write, the notices it would send (none delivered) and the outcome — and is kept only with a passing AVP verdict, compensating through inverses on failure; money steps are refused as irreversible.

- **Use:** mix mana.checkpoint --plan plan.json --actor <user id> --actor-resource MyApp.Accounts.User (dry run); add --keep --verdict .mana/sense/<run>/verdict.json to apply. In code: Mana.Checkpoint.dry_run(plan, actor) / keep(plan, actor, verdict). Plan: [{"resource": "MyApp.Operations.Booking", "id": ..., "verb": "accept", "params": {}}].
- **Instead of:** trying a data change for real to see what happens; asking a person to confirm every agent action; manual cleanup after an agent experiment
- **Docs:** `framework/ash/core/lib/mana/checkpoint.ex`

### Causal trace (`trace`)

Every Moments journey (browser or headless suite) links each gesture to the requests it made, the Ash actions they ran, the database time they took and — through Mana.History — which records changed and which fields, by name only; moments check prints the changes.

- **Use:** Already on in Moments runs: the app calls MomentActionTrace.attach(dio, Uri.parse(baseUrl)) (do it in the app's account package), the backend mounts Moments.ActionTrace.Plug in dev with config :ash, :tracer, [Moments.ActionTrace] and Moments.ActionTrace.Telemetry, and moments/backend.json defines MANA_ACTION_TRACE. Read it: framework/moments/moments suite <moment> --headless, then the report's actions.receipts[].changes, or moments check output ("changed: ...").
- **Instead of:** guessing which endpoint a button hits; print debugging across client and server; grepping logs for a request id
- **Docs:** `framework/ash/moments/README.md`

### Live examples (`examples`)

Next to a marked function, what it received and returned in each real Moment, recorded during Moments runs in development — change the rule, rerun the affected Moments and see which results moved, without opening a screen.

- **Use:** Server: use Mana.Examples; defexample price(lines, opening, services) do ... end (works as def); dev config :mana_core, :examples, dir: ".mana/examples". Run Moments (framework/moments/moments suite <names> --headless --project apps/<app>), then framework/cli/mana examples <fun> [--json]: per Moment the last arguments and result, and "changed" when it differs from the previous run (ids and timestamps ignored).
- **Instead of:** writing example inputs by hand in docs or tests; IO.inspect sprinkled to see real values; opening each screen to check a rule change
- **Docs:** `framework/ash/core/lib/mana/examples.ex`

### Whyline (`why`)

Why does the app show this value? The history entries that set a field to it, each as a causal slice — record and field, before and after, the verb that set it, who (user, agent, system deadline), when, and the Moment step whose gesture caused it.

- **Use:** mix mana.why "cancelled" [--json] (against the Moments instance database of the app) — reads the instance database's history and the suite reports. In code: Mana.Why.explain(Log, value, root: repo_root). Values are as stored (an enum's value, not its translated label).
- **Instead of:** grepping the code for who sets a field; reading logs to find which request changed a record; guessing which screen action caused a state
- **Docs:** `framework/ash/core/lib/mana/why.ex`

### Intervention (`intervention`)

Change one condition of a running app without editing it: net: makes matching API calls answer offline, api-error, slow or empty (the AVP conditions); latency: delays matching requests on the server; fn: makes a defexample function raise or answer a value; clock runs now the deadlines and stuck-flow checks that would come due; replay with rewritten params answers what would have happened if.

- **Use:** Client (Moments builds only): --dart-define=MANA_INTERVENE='net:/api/notifications/*=offline;net:/api/**=slow:1500' or MomentIntervention.set([...]) (attach it in the app's account package). Server (dev, config :mana_core, :interventions, true): MANA_INTERVENE="latency:/api/operations/**=1500;fn:MyApp.Operations.Actions.priced=raise" or Mana.Intervene.Rules.set([...]); clock: Mana.Intervene.advance(Repo, {3, :day}) or mix mana.advance 3d (not in production). Counterfactual: Mana.History.replay(Resource, entries, params: fn action, params -> Map.put(params, ...) end).
- **Instead of:** mocking the network by hand in each test; waiting for a real deadline to pass; editing code to see what an error does to a screen
- **Docs:** `framework/ash/core/lib/mana/intervene.ex`

### Agent evals (`evals`)

Whether agents actually use the framework: a task given with no hints (evals/<name>/task.md) runs in a throwaway worktree through the project's own agent (with its skills), and checks over the diff and commands decide it (checks.toml) into an AVP verdict with the agent's log, diff and token use.

- **Use:** framework/cli/mana eval list; mana eval run <name> [--agent claude|codex] [--keep] (minutes; spends model tokens). Declare a new one as evals/<name>/task.md + checks.toml ([[check]] kind = "diff" with files/pattern/absent, or kind = "command" with run/cwd). Receipts in .mana/evals/.
- **Instead of:** hoping agents find the primitives; judging agent work by reading it once
- **Docs:** `framework/cli/lib/src/evals.dart`

