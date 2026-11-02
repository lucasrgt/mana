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

  alias Mana.Graph

  @impl true
  def run(args) do
    {opts, query} =
      OptionParser.parse!(args, strict: [manifest: :keep, screens: :string, json: :boolean])

    Mix.Task.run("app.config")
    Mix.Task.run("compile")
    app = Mix.Project.config()[:app]

    graph =
      Graph.build(Application.fetch_env!(app, :ash_domains),
        manifests: manifests(Keyword.get_values(opts, :manifest)),
        screens: screens(opts[:screens])
      )

    print(answer(graph, query), opts[:json] == true or query == [])
  end

  defp manifests([]),
    do:
      Path.wildcard("../*/moments/manifest.json") ++ Path.wildcard("../*/*/moments/manifest.json")

  defp manifests(paths), do: paths

  defp screens(nil), do: %{}
  defp screens(path), do: path |> File.read!() |> Jason.decode!()

  defp answer(graph, []), do: Graph.to_json(graph)
  defp answer(graph, ["verbs-without-moment"]), do: Graph.query(graph, :verbs_without_moment)
  defp answer(graph, ["dead-verbs"]), do: Graph.query(graph, :dead_verbs)
  defp answer(graph, ["proves", verb]), do: Graph.query(graph, {:proves, verb})
  defp answer(graph, ["knob", name]), do: Graph.query(graph, {:knob, name})
  defp answer(graph, ["verb", verb]), do: Graph.query(graph, {:verb, verb})

  defp answer(_graph, other),
    do: Mix.raise("unknown query #{Enum.join(other, " ")}; see mix help mana.graph")

  defp print(answer, true), do: Mix.shell().info(Jason.encode!(answer, pretty: true))

  defp print(answer, false) when is_list(answer),
    do: Enum.each(answer, &Mix.shell().info(if(is_binary(&1), do: &1, else: inspect(&1))))

  defp print(answer, false), do: Mix.shell().info(inspect(answer, pretty: true))
end
