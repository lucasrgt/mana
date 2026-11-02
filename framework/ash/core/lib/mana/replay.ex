defmodule Mana.Replay do
  @moduledoc """
  Real traffic as a regression suite: every subject of an exported history
  log (`mix mana.history.export`) is rebuilt by the code compiled now
  (`Mana.History.replay/3`), and the result is compared with what was
  recorded.

      entries = Mana.Replay.read("history.jsonl")
      report = Mana.Replay.run(entries, domains: [MyApp.Bookings])

  Each subject replays inside a transaction that is rolled back (on a data
  layer that cannot, the rebuilt record is destroyed afterwards), so
  nothing stays written. Run it against a database that holds what the
  subjects refer to — a restore of production, or a `Mana.Snapshot` of one
  (`scope:`). Verbs declared `external:` refuse the replay unless
  `external: :skip`; redacted inputs cannot replay (`params:` may supply
  them, as for `Mana.History.replay/3`).

  A subject is `:same` when every field its entries recorded ends with the
  recorded value, `:diverged` with the fields that did not, `:refused`
  (external or redacted) or `:failed` (an action refused or crashed, with
  where). The report counts them per feature (the `feature:` of the
  verbs a subject's entries ran, else its type).
  """

  alias Ash.Domain.Info
  alias Mana.History

  require Logger

  @ignored ["id", "inserted_at", "updated_at", "created_at"]

  @doc "The entries of a JSON-lines export."
  def read(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(&Jason.decode!/1)
  end

  @doc """
  Replays `entries`. Options: `domains` (to find each subject's resource),
  `actor` (`fn actor_id -> actor end`; without it every action runs
  unauthorized, which compares behaviour, not permission), `external`
  (`:skip`), `params`, `times` (`:as_recorded` by default), `scope`
  (`{repo, scope_id}` of a `Mana.Snapshot`), `limit`.
  """
  def run(entries, opts \\ []) do
    resources =
      for domain <- List.wrap(opts[:domains]),
          resource <- Info.resources(domain),
          into: %{},
          do: {Mana.Entity.type(resource), resource}

    subjects =
      entries
      |> Enum.group_by(&{&1["subject_type"], to_string(&1["subject_id"])})
      |> Enum.sort_by(fn {key, _} -> key end)
      |> then(&if(opts[:limit], do: Enum.take(&1, opts[:limit]), else: &1))

    results =
      in_scope(opts[:scope], fn ->
        for {{type, id}, list} <- subjects,
            do: replay_subject(type, id, sort(list), resources, opts)
      end)

    %{
      subjects: length(results),
      results: results,
      by_feature:
        results
        |> Enum.group_by(& &1.feature)
        |> Map.new(fn {feature, list} -> {feature, Enum.frequencies_by(list, & &1.outcome)} end)
    }
  end

  defp in_scope(nil, fun), do: fun.()
  defp in_scope({repo, id}, fun), do: Mana.Snapshot.with_scope(repo, id, fun)

  defp sort(list), do: Enum.sort_by(list, &{&1["at"] || "", &1["id"] || ""})

  defp replay_subject(type, id, entries, resources, opts) do
    resource = Map.get(resources, type)
    feature = feature(resource, entries) || type
    base = %{subject: "#{type}:#{id}", type: type, feature: feature}

    cond do
      is_nil(resource) ->
        Map.merge(base, %{outcome: :failed, detail: "no resource of type #{type} in the domains"})

      not Enum.any?(entries, &(&1["outcome"] == "done")) ->
        Map.merge(base, %{outcome: :same, detail: "nothing was done"})

      true ->
        Map.merge(base, isolated(resource, fn -> compare(resource, entries, opts) end))
    end
  end

  defp isolated(resource, fun) do
    if Ash.DataLayer.data_layer_can?(resource, :transact) do
      case Ash.DataLayer.transaction([resource], fn ->
             Ash.DataLayer.rollback([resource], fun.())
           end) do
        {:error, result} when is_map(result) -> result
        other -> %{outcome: :failed, detail: "transaction: #{inspect(other)}"}
      end
    else
      fun.()
    end
  end

  defp compare(resource, entries, opts) do
    recorded = recorded(entries)

    replayed =
      History.replay(resource, Enum.map(entries, &as_export/1),
        actor: opts[:actor] || fn _ -> nil end,
        params: opts[:params] || fn _action, params -> params end,
        times: opts[:times] || :as_recorded,
        external: opts[:external]
      )

    case replayed do
      {:ok, nil, _} ->
        %{outcome: :same, detail: "nothing to rebuild"}

      {:ok, record, applied} ->
        fields = diverged_fields(record, recorded)
        cleanup(record)

        if fields == [],
          do: %{outcome: :same, applied: length(applied)},
          else: %{outcome: :diverged, fields: fields, applied: length(applied)}

      {:error, %{error: reason}} when reason in [:external, :redacted_input] ->
        %{outcome: :refused, detail: to_string(reason)}

      {:error, %{at: at, action: action, error: error}} ->
        %{outcome: :failed, detail: "entry #{at} (#{action}): #{error_text(error)}"}
    end
  rescue
    error -> %{outcome: :failed, detail: Exception.message(error) |> String.slice(0, 300)}
  end

  defp diverged_fields(record, recorded) do
    for {field, value} <- recorded,
        field not in @ignored,
        value != "[redacted]",
        now = record |> Map.get(String.to_existing_atom(field)) |> History.encode(),
        now != value,
        do: %{field: field, recorded: value, replayed: now}
  end

  # Without a transaction to roll back, the rebuilt record is removed.
  defp cleanup(record) do
    if Ash.DataLayer.data_layer_can?(record.__struct__, :transact),
      do: :ok,
      else: remove(record)
  end

  defp remove(record) do
    case Ash.destroy(record, authorize?: false) do
      {:error, error} ->
        Logger.warning(
          "Mana.Replay left a rebuilt #{inspect(record.__struct__)}: #{Exception.message(error)}"
        )

      _removed ->
        :ok
    end
  end

  defp recorded(entries) do
    for entry <- entries, entry["outcome"] == "done", reduce: %{} do
      state -> Map.merge(state, entry["after"] || %{})
    end
  end

  defp as_export(entry) do
    entry
    |> Map.take(["action", "verb", "actor_id", "actor_kind", "params", "outcome", "at"])
    |> Map.update("actor_kind", nil, &(&1 && to_string(&1)))
    |> Map.update("outcome", nil, &(&1 && to_string(&1)))
  end

  defp feature(nil, _entries), do: nil

  defp feature(resource, entries) do
    verbs = MapSet.new(entries, & &1["verb"])

    if Mana.Verbs in Spark.extensions(resource) do
      resource
      |> Mana.Verbs.declared()
      |> Enum.find_value(&(to_string(&1.name) in verbs && &1.feature))
    end
  end

  defp error_text(%{__exception__: true} = error),
    do: Exception.message(error) |> String.slice(0, 200)

  defp error_text(error), do: inspect(error) |> String.slice(0, 200)

  @doc "A person's reading of `report`."
  def format(report) do
    features =
      for {feature, counts} <- Enum.sort(report.by_feature) do
        parts =
          for outcome <- [:same, :diverged, :refused, :failed],
              n = Map.get(counts, outcome),
              do: "#{n} #{outcome}"

        "#{feature}: #{Enum.sum(Map.values(counts))} subjects, #{Enum.join(parts, ", ")}"
      end

    details =
      for result <- report.results, result.outcome in [:diverged, :failed] do
        case result do
          %{outcome: :diverged, fields: fields} ->
            "✗ #{result.subject}: " <>
              Enum.map_join(
                fields,
                "; ",
                &"#{&1.field} #{inspect(&1.recorded)} → #{inspect(&1.replayed)}"
              )

          %{detail: detail} ->
            "✗ #{result.subject}: #{detail}"
        end
      end

    Enum.join(["replayed #{report.subjects} subjects"] ++ features ++ details, "\n")
  end
end
