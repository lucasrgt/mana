# Mana Core

Small, opinionated Spark extensions for product contracts that Ash does not cover
natively. See `framework/docs/lazuli.md` for why each one exists.

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
