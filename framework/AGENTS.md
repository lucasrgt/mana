# Mana — architecture for agents

Mana is an Ash/Elixir + Flutter framework.
Preserve vertical slices, ordinary Elixir/Dart, and unrelated work. Read the affected
consumer and framework contracts before editing. Use installed dependency
versions and official documentation to resolve unfamiliar APIs.

## One framework

Every Mana piece is listed in `catalog.toml` with how to use it and what it
replaces; `cli/mana capabilities <topic>` searches it and
`agents/skills/mana/SKILL.md` is generated from it (`mana capabilities skill`).
Before writing code, find the capability and use it; add a catalog entry when a
new piece lands, or agents will not know it exists. Product features are
addressed as `feature:<name>` through the project's `features.toml`
(`mana features`).

A new fullstack piece is a primitive, not a one-off: a Spark extension that
`use Mana.Primitive, contract: "x-mana-<name>", catalog: "<id>", moments: [...]`
(see `Mana.Verbs`, `Mana.Views`, `Mana.Attachments`, `Mana.History`,
`Mana.Flow`, `Mana.Notifications`), its Dart half as a `PrimitiveWriter` in
`cli/lib/src/primitives.dart` plus types in `flutter/mana_primitives`, and its
`catalog.toml` entry. `mana client generate` refuses a contract key with no
writer and `mana doctor` refuses a primitive with no catalog entry, so a piece
cannot ship half-known.

## Comments

A comment, documentation included (`@moduledoc`, `@doc`, Dart `///`),
survives only when it says something the names and types cannot: a
non-obvious *why* (a library quirk, a security reason, a rejected
alternative), a domain rule the code only implies, or a contract a caller
would otherwise get wrong. Never narrate what the code visibly does:
"no registration yet: the read answers 404", "retention: the export goes",
"Takes a point off the map, or puts it back. False when the server refused."
on `updateActive(...) -> Future<bool>` restate the code and are deleted on
sight. Before finishing an edit, reread every comment in the lines you touched.

## Guarantee what can be guaranteed; constrain what can be constrained; review only what remains

Classify a **specific property within a stated boundary**, not an entire library:

| Level | Meaning | Required evidence |
| --- | --- | --- |
| `guaranteed` | Every supported path within the boundary enforces the property; an invalid declaration or operation is rejected. | Identify the enforcing mechanism, boundary, and a focused negative proof. An escape hatch that bypasses the property is outside this guarantee and must be explicit. |
| `default-safe` | The standard path uses a canonical implementation; custom code can bypass it. | Identify the native default, available escape hatches, and the responsibilities an override assumes. |
| `reviewed` | Domain or execution context requires an explicit judgment. | Review the affected behavior, record concrete findings and supporting observations, and state what remains unverified. |

Prompt instructions and successful tests alone are not runtime guarantees.
Do not describe Mana as making all invalid architectures impossible. Reclassify
a property if a new entry point or escape hatch invalidates its boundary.

Keep the classification separate from implementation and verification status.
`reviewed` identifies a property that requires contextual review; it does not
mean that a review has happened or passed. Likewise, a proposed invariant is
not `guaranteed` until its enforcing mechanism exists. When documenting an
architectural decision, name the property, affected resource/action or entry
point, level, enforcing mechanism or native default, bypasses, and evidence or
remaining uncertainty. Keep this in the affected contract or decision; do not
create a second global registry or mandatory report for every cosmetic edit.

## Native execution paths

- Persistence: Ash resources/actions with AshPostgres and the application's
  Ecto/DBConnection pool. Do not implement another pool or route general SQL
  through a single GenServer. Use processes for state, lifecycle, concurrency or
  fault isolation, not merely to organize functions. Legitimate serialized
  domain processes remain possible; explain their ownership and contention.
- Authorization and tenancy: Ash policies and native multitenancy where used.
  Propagate actor and tenant through HTTP, jobs and internal actions. Review
  `authorize?: false`, direct Repo/SQL and privileged paths locally; they must
  not silently replace the user-facing authorization boundary.
- Jobs: evaluate AshOban for resource-backed triggers/actions; use Oban directly
  where appropriate. Preserve retry/idempotency semantics. Do not invent durable
  queues or claim exactly-once external delivery.
- Realtime/presence: use Phoenix PubSub/Channels/Presence when required. Choose
  topic authorization, scope and deployment assumptions explicitly. Do not add
  Redis or another broker without a concrete requirement.
- State and lifecycle: AshStateMachine for declarative resource transitions
  where suitable; OTP processes and supervisors for runtime lifecycle. A state
  machine does not by itself guarantee transaction isolation or durable effects.
- Transactions: use Ash/Ecto facilities, database constraints and appropriate
  locking for the business invariant. Remote payments, email and webhooks are
  not rolled back by a database transaction; use durable intent and idempotency.

Ash is the semantic execution foundation, not a competing DSL to reimplement.
Mana owns integration, derived contracts, surfaces and Moments. Introduce a
new abstraction only for a demonstrated consumer need; keep generated wiring
thin. Never infer business policy, payment semantics or transaction boundaries
solely from a product label.

## Local architectural review

Before completing a change, inspect its affected resource/action, callers and
effects. Use the compiled contract/impact information where available; verify
uncertain edges in source. Do not invent capabilities or dependencies in the IR.

The direction for semantic selection is: changed resource/action → known
callers and effects → relevant review questions and Moments. For example, a
reservation confirmation that actually touches payment, authorization and a
transaction needs those reviews; its name alone does not establish those
dependencies. Unknown edges remain explicit uncertainty, not proof that the
change is safe. A presentation change only expands into backend review when
it also changes a backend contract or effect.

- Persistence/query changes: inspect serialization, connection ownership,
  bounded reads, N+1 and relevant indexes. Measure concurrent behavior when the
  change affects contention; a successful single request is insufficient.
- Authorization/tenancy changes: follow actor/tenant through the changed entry
  points and exercise the relevant denied/cross-owner scenario.
- Mutations/jobs/integrations: inspect transaction boundaries, failure/retry,
  duplicate delivery and irreversible effects. Use the affected Moments to
  observe persisted postconditions and isolate external effects.
  Review orphan recovery separately from retries. A local release restore kept
  an AshOban job `executing` after SIGKILL because Lifeline was available but not
  configured. Native rescue fixed the observed case; its age threshold must
  exceed legitimate worker runtimes and does not prevent duplicated effects.
  Do not infer that a listed
  or installed Oban service is active; inspect configuration and execution.
  A caller timeout/disconnect does not prove rollback: a local release probe
  observed eight timed-out creates commit after PostgreSQL resumed. Classify the
  outcome as uncertain, retain the operation identity and inspect its persisted
  effects before deciding what to do next. Do not automatically repeat a mutation
  because its response was lost. Retry safety must come from an explicit domain
  contract/idempotency mechanism, not from the prompt or an HTTP status alone.
  Also inspect retries below application code: a browser proof observed
  two POSTs after one gesture when the connection closed before response headers.
  A missing retry loop in Dart is not an at-most-once guarantee; use the
  creation identity of `ash/presentation` (`create_identity`).
  The Moments lease retains failed/interrupted journeys for attention; explicit
  recovery releases ownership, not database effects or late server work.
- Process/realtime changes: inspect supervision, mailbox/backpressure, shared
  state, topic authorization and lifecycle as relevant to the change.
- Presentation-only changes: verify the affected Flutter behavior; do not start
  an unrelated OTP/backend audit.

Report concrete defects with location, violated property, impact and correction.
Resolve observed defects within scope; distinguish uncertainty from a finding.
Use focused engine tests for protocol invariants and Moments for consumer
journeys. Do not add a global architectural reviewer, mandatory exhaustive
suite or approval ritual. `mix moments.review Resource action output.json`
can plan a review from compiled Ash metadata for an explicitly selected action;
see `ash/moments/README.md`. Its pending questions are not findings or approvals,
and its domain candidates are not proven action coverage. `moments review --plan
<plan.json> --evidence <journey.json>` associates historical positive observations
with that target without changing review status or excluding other candidates.
Never treat these editable local reports as current-source or deployment
attestations. Automatic selection
from a diff and complete effect/caller analysis remain future capabilities.

Moments follow the common protocol (`moments/protocol-v0.1.md`): `from` is the source of ancestry;
plans select declared paths and observed events supply execution evidence.
Restored presentation, restored full situation and verified behavior are
different claims. Keep credentials and disposable evidence private.


## Dependency-authored agent guidance

A consumer can use native `usage_rules` as a dev-only dependency to sync
installed authors' rules into its `AGENTS.md` and on-demand agent skills
(`mix usage_rules.sync`). Consult relevant dependency rules when available, without
turning prompt guidance into a runtime guarantee or a global verification gate.
