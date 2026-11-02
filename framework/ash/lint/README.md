# Mana Lint

A Credo plugin with checks for what Ash and Mana expect and Credo does not
know, and for code that reimplements a Mana primitive. Every check reads the
AST and recognizes a legitimate exception from the code itself (the module
that is the notifications sender, Mana's own modules); a project tunes it
with params in `.credo.exs`, never with `credo:disable` or a comment.

```elixir
# mix.exs
{:mana_lint, path: "../mana/framework/ash/lint", only: [:dev, :test], runtime: false}

# .credo.exs
%{configs: [%{name: "default", strict: true, plugins: [{ManaLint, []}]}]}
```

`mix credo --strict` then runs the checks below with Credo's own (the plugin
loads from the build, so compile first). `mix credo explain <file>:<line>`
prints why a finding is not idiomatic and what to write instead.

| Check | Flags |
|---|---|
| `AshEffectInTransactionHook` | an effect (payment adapter, storage put/delete, mailer, HTTP client, push, PubSub/Endpoint broadcast, `Mana.Entity.announce`) in a function given to `before_action`/`after_action`/`around_action` or to `Ash.transact`/`Repo.transaction`, or in a `change/3` body; a broadcast or notice in `after_transaction`. Calls are followed through the project's functions. Not `before_transaction`, `Oban.insert`, notifiers, `Mana.Privacy.erase` (it follows the transaction) |
| `AshSeedOutsideSeeds` | `Ash.Seed.*` outside tests, seeds, Moments recipes and support code |
| `DirectRepoOnResource` | `Repo.*`/`Ecto.Adapters.SQL.query*` or an Ecto `from` on a table a resource declares (advisory locks and probes name none) |
| `RawSqlInCalculation` | `Repo.*`/SQL, or an `Ash.get/read*` per record, inside a calculation |
| `AshCallInLoop` | an Ash read or write per element of `Enum.*`/`Stream.*`/`for` over records of an Ash read |
| `ManualActorAuthorization` | a read with `authorize?: false` whose result is compared with `actor.id` in `run/3`, `change/3` or `validate/3` |
| `ValidationAsChange` | `add_error` in `change/3` on a condition of the changeset alone |
| `GetOrCreate` | a `read_one`/`get` that found nothing followed by a `create`, without `upsert?` |
| `AggregateInElixir` | a read's records counted, summed or maxed in Elixir (a page read with `limit` is not) |
| `InMemoryFilterAfterRead` | a read's records filtered in Elixir by a plain field comparison |
| `UnsupervisedProcess` | `spawn*`, `Task.start`, `Process.register` guarded by a rescue, `Process.sleep` outside interventions, fakes and Moments |
| `PersistentTermHotWrite` | `:persistent_term.put` whose value or branch depends on a time |
| `TableScanCron` | an Oban worker that filters a timestamp against now and iterates |
| `BroadRescue` | `rescue _ ->` / `catch _, _ ->` that neither re-raises nor reports |
| `ExternalPostWithoutIdempotencyKey` | a POST from a configured client module without an idempotency key |
| `RecordBroadcast` | a PubSub/Endpoint broadcast in a resource, change, notifier or manual action, or next to an Ash write: use `Mana.Entity`. Not the module that defines `broadcast/3` (the entity's broadcaster) |
| `RecordDateJob` | a job whose `scheduled_at:`/`schedule_in:` comes from a record's date field: use a `Mana.Entity` deadline (an event for another system: `Mana.Webhook.deliver(..., at:)`). Not a fixed delay, not Mana's own workers |
| `ImperativeNotice` | `*.Notifications.notify(!)` called by hand: declare the notice (`Mana.Notifications`). Not in the module with `@behaviour Mana.Notifications.Sender` |
| `BrazilianIdentifier` | a function named for validating/formatting a CPF, CNPJ, CEP or plate, or a regex for their digit groups: use the `Mana.BR` types. Not in `Mana.BR` |

## Params

Each check's defaults are in its explanation. A param given for a check in
`checks:` replaces that default:

```elixir
checks: %{
  extra: [
    {ManaLint.Check.AshEffectInTransactionHook,
     effects: [~r/(^|\.)Stripe\./, MyApp.Sms, ":telemetry.execute"]},
    {ManaLint.Check.ExternalPostWithoutIdempotencyKey, clients: [~r/Stripe/, "MyApp.Pix"]}
  ]
}
```

Call patterns are a module (all its functions), `"Mod.fun"`, `{Mod, :fun}` or a
regex matched against `"Mod.fun"`; paths and module lists take regexes or
substrings.

## What a check proves

Nothing beyond its pattern: a check sees the code as written — aliases,
pipes, the module's functions and, for the project-wide checks
(`AshEffectInTransactionHook`, `DirectRepoOnResource`,
`InMemoryFilterAfterRead`), every source file Credo reads. Effects reached
through a dependency, dynamic dispatch (`apply/3`, an adapter in a variable)
or an action run inside the hook (`Ash.update` whose own hooks call Stripe)
are not followed. No finding is not a review.

## Develop

```sh
mix test
mix format --check-formatted
mix compile && mix credo --strict   # the package checks itself with the plugin
```
