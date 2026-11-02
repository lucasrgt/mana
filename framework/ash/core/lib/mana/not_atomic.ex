defmodule Mana.NotAtomic do
  @moduledoc false
  # Mana's per-record lock (`Mana.Lock`, taken by Mana.Entity.Changed and
  # Mana.Verbs.Recheck) runs as a before_action hook, which Ash cannot run
  # inside an atomic update, so Ash refuses those actions. `which` names the
  # actions that take it: every update and destroy of a live entity, and on
  # other resources only the actions of a verb whose `when` is rechecked
  # (idempotent verbs are not). The lock is only taken on Postgres, so only
  # there are they marked; elsewhere an atomic update keeps checking the
  # stored row, which the lock does on Postgres. Every other action stays as
  # its resource declares it, atomic by default.
  alias Spark.Dsl.Transformer

  def mark(dsl, which) do
    if Transformer.get_persisted(dsl, :data_layer) == AshPostgres.DataLayer,
      do: mark!(dsl, which),
      else: dsl
  end

  defp mark!(dsl, which) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:update, :destroy] and which.(&1)))
    |> Enum.reduce(dsl, fn action, dsl ->
      Transformer.replace_entity(
        dsl,
        [:actions],
        %{action | require_atomic?: false},
        &(&1.name == action.name and &1.type == action.type)
      )
    end)
  end
end
