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

What the app knows about itself (`framework/docs/prd-self-knowing.md`):

- `Mana.Explore` — walks the reachable states from the declarations (offered
  verbs, collection verbs, probes, the clock) and checks offer honesty,
  enforced refusals, idempotence, inverses, reconcile rules (timed ones on a
  moved clock), flows and history replay; violations shrink to their shortest
  moves. `mix mana.explore`; `Mana.Explore.Lock` and `mix mana.affordances`
  keep the affordance graph as a committed `affordances.json`.
- `Mana.Reconcile` — `within:`/`since:`: how long a record may stay in scope.
- `Mana.Snapshot` — Postgres template clones: a migrated base, scopes with
  their own pool, snapshots, forks and diffs; `Mana.Snapshot.Plug` runs a
  request carrying `x-mana-data-scope` on its scope (development only).
- `Mana.Graph` — the program graph from Spark introspection, Moments
  manifests and screen references; `mix mana.graph` (and `mana graph`).
- `Mana.Replay` — an exported history log replayed against the current code
  in rolled-back transactions, compared per feature; `mix mana.replay`.
- `Mana.Undo` — the newest change of a person taken back through its verb's
  inverse, recorded as `via: "undo:<id>"`.
