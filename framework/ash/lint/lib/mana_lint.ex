defmodule ManaLint do
  @moduledoc """
  Credo checks for what Mana and Ash expect and Credo does not know. Enable
  them all in `.credo.exs`:

      %{configs: [%{name: "default", plugins: [{ManaLint, []}]}]}

  Every check runs with its default params; a project tunes one in `checks:`
  (`extra: [{ManaLint.Check.AshEffectInTransactionHook, effects: [...]}]`), and
  `mix credo explain` on a finding shows the check, its params and defaults.
  A param list given there replaces that default list.
  """

  import Credo.Plugin

  @checks [
    ManaLint.Check.AshEffectInTransactionHook,
    ManaLint.Check.AshSeedOutsideSeeds,
    ManaLint.Check.DirectRepoOnResource,
    ManaLint.Check.RawSqlInCalculation,
    ManaLint.Check.AshCallInLoop,
    ManaLint.Check.ManualActorAuthorization,
    ManaLint.Check.ValidationAsChange,
    ManaLint.Check.GetOrCreate,
    ManaLint.Check.AggregateInElixir,
    ManaLint.Check.InMemoryFilterAfterRead,
    ManaLint.Check.UnsupervisedProcess,
    ManaLint.Check.PersistentTermHotWrite,
    ManaLint.Check.TableScanCron,
    ManaLint.Check.BroadRescue,
    ManaLint.Check.ExternalPostWithoutIdempotencyKey,
    ManaLint.Check.RecordBroadcast,
    ManaLint.Check.RecordDateJob,
    ManaLint.Check.ImperativeNotice,
    ManaLint.Check.BrazilianIdentifier
  ]

  @doc "The checks the plugin enables."
  def checks, do: @checks

  @doc false
  def init(exec), do: register_default_config(exec, config())

  @doc false
  def config do
    inspect(
      %{configs: [%{name: "default", checks: %{extra: Enum.map(@checks, &{&1, []})}}]},
      limit: :infinity
    )
  end
end
