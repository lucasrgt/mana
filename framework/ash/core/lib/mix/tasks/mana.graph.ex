defmodule Mix.Tasks.Mana.Graph do
  @shortdoc "Asks the program graph (Mana.Graph): verbs without a Moment, dead verbs, what a knob guards"
  @moduledoc """
      mix mana.graph verbs-without-moment
      mix mana.graph dead-verbs
      mix mana.graph proves booking.pay
      mix mana.graph knob coupons_enabled
      mix mana.graph verb booking.pay
      mix mana.graph --json                       # the whole graph

  Options: `--manifest path` (repeatable; by default every
  `moments/manifest.json` one or two folders above the backend),
  `--screens file.json` (`{"booking.pay": ["lib/..."]}`, what `mana graph`
  finds in the Dart sources), `--json`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, query} =
      OptionParser.parse!(args, strict: [manifest: :keep, screens: :string, json: :boolean])

    Mix.Task.run("app.config")
    Mix.Task.run("compile")
    app = Mix.Project.config()[:app]

    manifests =
      case Keyword.get_values(opts, :manifest) do
        [] ->
          Path.wildcard("../*/moments/manifest.json") ++
            Path.wildcard("../*/*/moments/manifest.json")

        paths ->
          paths
      end

    screens = if path = opts[:screens], do: path |> File.read!() |> Jason.decode!(), else: %{}

    graph =
      Mana.Graph.build(Application.fetch_env!(app, :ash_domains),
        manifests: manifests,
        screens: screens
      )

    answer =
      case query do
        [] -> Mana.Graph.to_json(graph)
        ["verbs-without-moment"] -> Mana.Graph.query(graph, :verbs_without_moment)
        ["dead-verbs"] -> Mana.Graph.query(graph, :dead_verbs)
        ["proves", verb] -> Mana.Graph.query(graph, {:proves, verb})
        ["knob", name] -> Mana.Graph.query(graph, {:knob, name})
        ["verb", verb] -> Mana.Graph.query(graph, {:verb, verb})
        other -> Mix.raise("unknown query #{Enum.join(other, " ")}; see mix help mana.graph")
      end

    cond do
      opts[:json] == true or query == [] ->
        Mix.shell().info(Jason.encode!(answer, pretty: true))

      is_list(answer) ->
        Enum.each(answer, &Mix.shell().info(if(is_binary(&1), do: &1, else: inspect(&1))))

      true ->
        Mix.shell().info(inspect(answer, pretty: true))
    end
  end
end
