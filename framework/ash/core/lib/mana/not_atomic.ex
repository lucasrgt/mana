defmodule Mana.NotAtomic do
  @moduledoc false
  # Mana's per-record lock (Mana.Entity.Changed, Mana.Verbs.Recheck) runs as a
  # before_action hook, which Ash cannot run inside an atomic update, so Ash
  # refuses those actions. The lock is only taken on Postgres, so only there are
  # the actions that carry it marked; elsewhere an atomic update keeps checking
  # the stored row, which the lock does on Postgres.
  alias Spark.Dsl.Transformer

  def mark(dsl, which) do
    if Transformer.get_persisted(dsl, :data_layer) == AshPostgres.DataLayer, do: mark!(dsl, which), else: dsl
  end

  defp mark!(dsl, which) do
    dsl
    |> Transformer.get_entities([:actions])
    |> Enum.filter(&(&1.type in [:update, :destroy] and which.(&1)))
    |> Enum.reduce(dsl, fn action, dsl ->
      Transformer.replace_entity(dsl, [:actions], %{action | require_atomic?: false}, &(&1.name == action.name and &1.type == action.type))
    end)
  end
end
