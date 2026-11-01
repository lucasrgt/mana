defmodule Mana.Undo do
  @moduledoc """
  Undo from history, through the verbs' declared inverses.

  `last/3` answers the change a person may take back now: the newest done
  entry of the record's `Mana.History`, made by this actor, whose verb
  declares an `inverse` the record offers the actor now — and not itself an
  undo. `undo/3` performs that inverse with the action context
  `mana_undo_of: <entry id>`, so its own entry records `via: "undo:<id>"`.
  Only the newest change can be undone: taking back an older one under a
  newer one would undo on top of something the person did not see.
  `within: {5, :minute}` limits how old that change may be.
  """
  require Ash.Query

  @doc "The change `actor` may undo on `record` now, or nil: `%{entry: entry, verb: verb, inverse: inverse}`."
  def last(record, actor, opts \\ []) do
    resource = record.__struct__

    with true <- Mana.History in Spark.extensions(resource) and Mana.Verbs in Spark.extensions(resource),
         log when not is_nil(log) <- Mana.History.log(resource),
         %{} = entry <- newest(log, resource, record.id),
         true <- mine?(entry, actor) and not undo?(entry) and recent?(entry, opts[:within]),
         %{inverse: inverse_name} = verb when not is_nil(inverse_name) <- verb(resource, entry.verb),
         true <- to_string(inverse_name) in Mana.Verbs.offered(record, actor) do
      %{entry: entry, verb: verb, inverse: verb(resource, to_string(inverse_name))}
    else
      _ -> nil
    end
  end

  @doc "Performs the inverse of `last/3`'s change; `{:ok, record}` or `{:error, :nothing_to_undo}`."
  def undo(record, actor, opts \\ []) do
    case last(record, actor, opts) do
      nil ->
        {:error, :nothing_to_undo}

      %{entry: entry, inverse: inverse} ->
        record
        |> Ash.Changeset.for_update(Mana.Verbs.action(inverse), %{}, actor: actor, context: %{mana_undo_of: entry.id})
        |> Ash.update()
    end
  end

  defp newest(log, resource, id) do
    log
    |> Ash.Query.filter(subject_type == ^Mana.Entity.type(resource) and subject_id == ^to_string(id) and outcome == :done)
    |> Ash.Query.sort(at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(authorize?: false)
  end

  defp mine?(entry, actor), do: actor != nil and entry.actor_kind == :user and to_string(entry.actor_id) == to_string(Map.get(actor, :id))
  defp undo?(entry), do: is_binary(entry.via) and String.starts_with?(entry.via, "undo:")

  defp recent?(_entry, nil), do: true
  defp recent?(entry, window), do: DateTime.diff(DateTime.utc_now(), entry.at, :second) <= Mana.Reconcile.within_seconds(window)

  defp verb(_resource, nil), do: nil
  defp verb(resource, name), do: Enum.find(Mana.Verbs.declared(resource), &(to_string(&1.name) == name))
end
