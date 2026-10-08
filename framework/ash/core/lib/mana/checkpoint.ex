defmodule Mana.Checkpoint do
  @moduledoc """
  What an agent does to data, tried before it counts: a plan of verb steps
  (`%{"resource" => "MyApp.Booking", "id" => id, "verb" => "cancel", "params" => %{}}`)
  runs once inside a transaction that is always rolled back (`dry_run/2`),
  answering what would change — the history entries the steps write, the
  notices they would send (none is delivered) and the outcome — and runs for
  real (`keep/3`) only with a passing AVP verdict, compensating through
  inverses when a step fails. A step whose verb moves money or reaches an
  outside system (`external:`) is irreversible outside a sandbox: a dry run
  refuses the plan instead of pretending.
  `mix mana.checkpoint` gives agents the same two verbs.
  """

  @doc "Runs `plan` as `actor` and rolls everything back; answers the report."
  def dry_run(plan, actor) do
    with {:ok, steps} <- load(plan, actor),
         [] <- irreversible(steps),
         {:ok, resources} <- transactional(steps) do
      Process.put(:mana_dry_run, [])

      result =
        Ash.DataLayer.transaction(resources, fn ->
          outcome = Mana.Verbs.run_all(steps, actor)
          Ash.DataLayer.rollback(resources, %{outcome: summary(outcome), history: history(steps)})
        end)

      notices = Process.delete(:mana_dry_run) |> Enum.reverse()

      case result do
        {:error, %{outcome: _} = report} -> {:ok, Map.put(report, :notices, notices)}
        other -> {:error, other}
      end
    else
      [_ | _] = money -> {:error, %{irreversible: money}}
      {:error, _} = error -> error
    end
  end

  @doc "Runs `plan` for real when `verdict` (an AVP verdict) passed."
  def keep(plan, actor, verdict) do
    if verdict_passed?(verdict) do
      with {:ok, steps} <- load(plan, actor), do: {:ok, summary(Mana.Verbs.run_all(steps, actor))}
    else
      {:error, :verdict_not_green}
    end
  end

  defp verdict_passed?(%{"outcome" => "pass"}), do: true
  defp verdict_passed?(%{outcome: outcome}) when outcome in [:pass, "pass"], do: true
  defp verdict_passed?(_), do: false

  defp load(plan, actor) do
    Enum.reduce_while(plan, {:ok, []}, fn step, {:ok, steps} ->
      resource = step["resource"] |> String.trim_leading("Elixir.") |> String.split(".") |> Module.safe_concat()

      case Ash.get(resource, step["id"], actor: actor) do
        {:ok, record} -> {:cont, {:ok, steps ++ [{record, String.to_existing_atom(step["verb"]), step["params"] || %{}}]}}
        {:error, error} -> {:halt, {:error, %{step: step, error: error}}}
      end
    end)
  end

  defp irreversible(steps) do
    for {record, name, _} <- steps,
        verb = Enum.find(Mana.Verbs.declared(record.__struct__), &(&1.name == name)),
        verb && (verb.risk == :money or not is_nil(verb.external)),
        do: %{resource: inspect(record.__struct__), id: record.id, verb: name}
  end

  defp transactional(steps) do
    resources = steps |> Enum.map(fn {record, _, _} -> record.__struct__ end) |> Enum.uniq()

    if Enum.all?(resources, &Ash.DataLayer.data_layer_can?(&1, :transact)),
      do: {:ok, resources},
      else: {:error, :cannot_roll_back}
  end

  defp history(steps) do
    for {record, _, _} <- steps,
        resource = record.__struct__,
        Mana.History in Spark.extensions(resource),
        uniq: true do
      {Mana.Entity.type(resource), record.id, Mana.History.export(Mana.History.log(resource), Mana.Entity.type(resource), record.id)}
    end
    |> Enum.uniq_by(fn {type, id, _} -> {type, id} end)
    |> Enum.map(fn {type, id, entries} -> %{subject: "#{type}:#{id}", entries: entries} end)
  end

  defp summary({:ok, records}), do: %{status: :done, records: Enum.map(records, &%{resource: inspect(&1.__struct__), id: &1.id})}

  defp summary({:error, %{failed: index, error: error} = failure}),
    do: %{status: :failed, step: index, error: Mana.History.error_code(error), compensated: length(failure.compensated), uncompensated: length(failure.uncompensated)}
end
