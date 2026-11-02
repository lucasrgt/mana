# Mana Core

Small, opinionated Spark extensions for product contracts that Ash does not cover
natively. `framework/catalog.toml` says what each one replaces and how to use it.

- `Mana.Domain` — `errors` catalog: stable codes and 4xx status per refusal;
  `Domain.error(:name)` builds a `Mana.Error`; `Mana.Domain.OpenApi` exports the
  codes as the `ErrorCode` enum.
- `Mana.Resource` — `access`: which actions are public (no session) and their rate
  limits, enforced inside the action. A public action must decide its rate limit.
- `Mana.Router` — derives public routes for the identity plug from `access`.
- `Mana.Integration` — provider slots with adapters per environment; production
  refuses to boot with a fake or unconfigured adapter.
- `Mana.Resource` — `retention`: `delete_after :expires_at, days: 30`; rows past it are
  deleted by `Mana.Retention.purge/1`, scheduled through `Mana.Retention.Worker` (Oban).
- `Mana.Lock` — `record(repo, "type:id")`: the per-record transaction lock
  (64-bit advisory key) that `Mana.Entity` and verb rechecks take. Only the
  update and destroy actions that take it are made non-atomic.
- `Mana.Resource` — `privacy`: `export` (what the person receives) and
  `personal` (which of those say who they are: what erasure scrubs from
  history and an incident replaces).
- `Mana.Search` — free-text search over string, string-array and embedded
  fields (`services: :label`), accent-insensitive with `unaccent: true`, in
  the query on AshPostgres.
- `Mana.Webhook` — provider webhooks received over the raw body; events
  delivered to another system's webhook through an Oban job inserted with
  the change, signed and retried (`Mana.Webhook.deliver/4`).
- `Mana.Verbs` — a read loading `verbs` answers every record's `when` in its
  own query; a policy or action that errors while the offer is checked goes to
  the `:error_reporter` instead of silently hiding the verb.

Processes the app starts in its supervision tree (each owns a table; without
it the piece refuses to run instead of starting one of its own):

```elixir
children = [Mana.Knobs.Cache, Mana.Notifications.Groups, Mana.Feature, ...]
```

- `Mana.Knobs.Cache` — the shared knob values each node rereads every
  `knob_ttl_ms`; reading or changing a knob raises without it.
- `Mana.Notifications.Groups` — `group_within` windows (per node); a resource
  that groups refuses its notifying actions without it.
- `Mana.Feature` — per-feature request health.

Notices are an outbox where the app runs Oban on the resource's repo: one job
per notice, inserted in the action's transaction, a failed channel retried by
its own job. Without Oban they go out after commit, not durably
(`Mana.Notifications`).

A destroyed `Mana.Uploads` file (`Mana.Privacy.erase/2` included) keeps its
stored objects until the destroy commits: with Oban, a job inserted in the
destroy's transaction deletes them, retried, an object already gone counting
as deleted; without it, an Ash notifier deletes them after the outermost
commit.

What the app knows about itself (`framework/docs/prd-self-knowing.md`):

- `Mana.Explore` — walks the reachable states from the declarations (offered
  verbs, collection verbs, probes, the clock) and checks offer honesty,
  enforced refusals, idempotence, inverses, reconcile rules (timed ones on a
  moved clock), flows and history replay; violations shrink to their shortest
  moves. A record's history is replayed with the original set aside, so a
  unique identity or an upsert never meets it, together with the records
  that reference it in the order the entries were recorded; a history that
  starts with an update is seeded from the row before it. A seed gives the
  same run and the same `affordances.json` bytes: records met together are
  ordered by content, not timestamps or ids. What it cannot use (a resource
  without a primary read, a part that raises) is reported once, in the
  report, never logged per move. `mix mana.explore`; `Mana.Explore.Lock` and
  `mix mana.affordances` keep the affordance graph as a committed
  `affordances.json`.
- `Mana.Reconcile` — `within:`/`since:`: how long a record may stay in scope;
  `holds: expr(...)` is asked in the query (only diverging records are read;
  negated and compound expressions included),
  `{Module, :fun}` per streamed record; a crashing repair is reported.
- `Mana.Snapshot` — Postgres template clones: a migrated base, scopes with
  their own pool, snapshots, forks and diffs; `Mana.Snapshot.Plug` runs a
  request carrying `x-mana-data-scope` on its scope (development only).
- `Mana.Graph` — the program graph from Spark introspection, Moments
  manifests and screen references; `mix mana.graph` (and `mana graph`).
- `Mana.Replay` — an exported history log replayed against the current code
  in rolled-back transactions, compared per feature; a subject whose entries
  start with an update is rebuilt from its row before them; `mix mana.replay`.
- `Mana.Undo` — the newest change of a person taken back through its verb's
  inverse, recorded as `via: "undo:<id>"`.
- `Mana.Incident` — a record's history up to a moment, with what it references,
  anonymized (privacy `personal` fields, people as roles with stand-ins made
  once per role) into a fixture a recipe replays into the same situation,
  every record's entries in recorded order (`Mana.History.replay_all/2`);
  `mix mana.incident booking:<id> --at <iso>`.

Tests run on ETS. With `MANA_TEST_POSTGRES=ecto://user:pass@host/db` the
`:postgres` tests also run, on AshPostgres resources (`test/support/postgres`):
per-record locks and `Recheck` under contention, a deadline racing a payment,
announcements, notices and history telemetry only after commit, history
entries atomic with their change, erasure scrubbing history and deleting
stored files only after commit, negated and compound reconcile `holds` in
SQL, embedded-field search, outbound webhooks after commit, an incident
reopened into the same booking, incidents and explored histories whose
steps need another record's later state or start with an update, and
`Mana.Explore` through `Mana.Snapshot` scopes (records with a unique
identity rebuilt beside the original). The database named in the URL
is dropped and cloned from a migrated template for each test module.
