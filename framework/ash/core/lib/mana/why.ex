defmodule Mana.Why do
  @moduledoc """
  Whyline over the history: why does the screen show this value? `explain/3`
  finds the history entries (`Mana.History`) that set a field to `value` —
  exactly, or as text containing it — and answers each causal slice, newest
  first: the record and field, the value before and after, the verb or
  action that set it, who did it (user, agent, system deadline), when, and
  the Moments gesture it happened in, named as the Moment and step when a
  suite report under `root` ran it. `mix mana.why "Cancelada"` prints them;
  `--json` gives agents the same slices.
  """
  require Ash.Query

  def explain(logs, value, opts \\ []) do
    text = to_string(value)
    steps = if root = opts[:root], do: gesture_steps(root), else: %{}

    for log <- List.wrap(logs),
        entry <- log |> Ash.Query.for_read(:read) |> Ash.Query.filter(outcome == :done) |> Ash.Query.sort(at: :desc) |> Ash.Query.limit(opts[:scan] || 2000) |> Ash.read!(authorize?: false),
        {field, after_value} <- entry.after,
        matches?(after_value, text) do
      gesture = entry.trace && String.replace_prefix(entry.trace, "gesture:", "")

      %{
        record: "#{entry.subject_type}:#{entry.subject_id}",
        field: field,
        before: Map.get(entry.before, field),
        after: after_value,
        set_by: entry.verb || entry.action,
        summary: entry.summary,
        actor: %{kind: entry.actor_kind, id: entry.actor_id, via: entry.via},
        at: entry.at,
        gesture: gesture,
        moment: gesture && steps[gesture]
      }
    end
    |> Enum.take(opts[:limit] || 20)
  end

  defp matches?(value, text) when is_binary(value), do: value == text or String.contains?(value, text)
  defp matches?(value, text) when is_number(value) or is_atom(value), do: to_string(value) == text
  defp matches?(_value, _text), do: false

  @doc "Gesture id → \"app:moment step <name>\" from the suite reports under `root`."
  def gesture_steps(root) do
    root
    |> Path.join("apps/*/moments/.suite/run-*/summary.json")
    |> Path.wildcard(match_dot: true)
    |> Enum.flat_map(&summary_steps(&1, root))
    |> Map.new()
  end

  # One unreadable or unexpected file skips itself, not the rest.
  defp summary_steps(summary, root) do
    app = summary |> Path.split() |> Enum.at(-5)

    with {:ok, body} <- File.read(summary),
         {:ok, %{"results" => results}} when is_list(results) <- Jason.decode(body) do
      for %{"name" => name, "report" => report} when is_binary(report) <- results,
          step <- report_steps(local(report, root)),
          do: {step["id"], "#{app}:#{name} step #{step["name"]}"}
    else
      _ -> []
    end
  end

  defp report_steps(report) do
    with {:ok, body} <- File.read(report),
         {:ok, %{"steps" => steps}} when is_list(steps) <- Jason.decode(body) do
      for %{"id" => id} = step when is_binary(id) <- steps, do: step
    else
      _ -> []
    end
  end

  # Reports name absolute paths of the machine that ran them; inside a
  # container the same tree sits under `root`.
  defp local(report, root) do
    if File.exists?(report) or not String.contains?(report, "/apps/"),
      do: report,
      else: Path.join(root, "apps/" <> (report |> String.split("/apps/", parts: 2) |> List.last()))
  end
end
