# Contracts

How a Mana app reaches a client over JSON:API: the transport half of Mana, which
`mana_core` does not depend on. A Mana app that serves a generated client (the
Flutter adapter) uses it; one that only renders LiveView does not need it.

- `Contracts.OpenApi` — OpenAPI 3.0 compatibility for the pinned AshJsonApi exporter.
- `Mana.Domain.OpenApi` — finishes the exported map: the `ErrorCode` enum, one
  component per `Mana.Enum` and `Mana.Shape`, each primitive's contract on its
  resource's schema (`x-mana-*`, listed under `info.x-mana-primitives`) and
  `x-mana-verb` on each operation.
- `Mana.Router` — the public JSON:API routes, from each resource's `access`.
- `Mana.Feature.Plug` — labels each JSON:API request with its feature and records it
  in `Mana.Feature` (the store, in `mana_core`).
- `Mana.Error` as a JSON:API error (`AshJsonApi.ToJsonApiError`).
- `mix contracts.export` — writes the normalized contract without starting the app.

Its tests run against `mana_core`'s fixture resources (`../core/test/fixtures`).
