defmodule Mix.Tasks.Mana.Why do
  @shortdoc "Why the app shows a value: the history entries that set it"
  @moduledoc """
      mix mana.why "<value>" [--log MyApp.HistoryEntry] [--root ..] [--json]

  Prints each causal slice `Mana.Why.explain/3` finds: which record's field
  became the value, through which verb and by whom, and in which Moment step.
  `--log` defaults to every resource using `Mana.History.Log` in the app's
  domains; `--root` (default `..`) is where the Moments suite reports live.
  """
  use Mix.Task

  alias Ash.Domain.Info
  alias Mana.Why

  # Reading the history needs the repositories, not the server: a running
  # development server keeps its port.
  defp start(app) do
    Mix.Task.run("app.config")

    case Application.get_env(app, :ecto_repos, []) do
      [] ->
        Mix.Task.run("app.start")

      repos ->
        {:ok, _} = Application.ensure_all_started(:ecto_sql)
        Enum.each(repos, & &1.start_link())
    end
  end

  @impl true
  def run(args) do
    {opts, [value | _]} =
      OptionParser.parse!(args, strict: [log: :keep, root: :string, json: :boolean])

    app = Mix.Project.config()[:app]
    start(app)

    logs = logs(app, Keyword.get_values(opts, :log))
    slices = Why.explain(logs, value, root: Path.expand(opts[:root] || ".."))

    if opts[:json] do
      Mix.shell().info(Jason.encode!(slices, pretty: true))
    else
      if slices == [],
        do: Mix.shell().info("No recorded change set a field to #{inspect(value)}.")

      Enum.each(slices, &Mix.shell().info(sentence(&1)))
    end
  end

  defp logs(app, []) do
    for domain <- Application.fetch_env!(app, :ash_domains),
        r <- Info.resources(domain),
        Mana.History.Log in Spark.extensions(r),
        do: r
  end

  defp logs(_app, names), do: Enum.map(names, &(&1 |> String.split(".") |> Module.safe_concat()))

  defp sentence(s) do
    "#{s.record} #{s.field}: #{inspect(s.before)} → #{inspect(s.after)} · #{s.set_by} (#{s.summary}) by #{s.actor.kind}#{via(s.actor.via)} at #{s.at}" <>
      where(s)
  end

  defp via(via) when via in [nil, false], do: ""
  defp via(via), do: " #{via}"

  defp where(%{moment: moment}) when moment not in [nil, false], do: " · #{moment}"
  defp where(%{gesture: gesture}) when gesture not in [nil, false], do: " · gesture #{gesture}"
  defp where(_slice), do: ""
end
