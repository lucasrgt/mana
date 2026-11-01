defmodule Mana.Graph do
  @moduledoc """
  One graph of the program, derived from what is declared: resources, their
  verbs, views, flow steps, reconcile rules, deadlines, knobs and features
  from Spark introspection; Moments from their exported manifests (the steps
  and checks that name a verb); screens from the verb references the Dart
  side found (`mana graph` passes them).

      graph = Mana.Graph.build(domains, manifests: ["../app/moments/manifest.json"], knobs: MyApp.Knobs)
      Mana.Graph.query(graph, :verbs_without_moment)

  Nodes are `%{id: "verb:booking.pay", kind: :verb, ...}`; edges are
  `{from, relation, to}`. Nothing is stored: every query answers from the
  declarations as they are now.
  """

  defstruct nodes: %{}, edges: []

  @doc """
  Builds the graph. Options: `manifests` (paths of Moments manifests),
  `knobs` (the app's `Mana.Knobs` module; `config :mana_core, :knobs` by
  default), `screens` (`%{"booking.pay" => ["lib/booking/view.dart"]}`).
  """
  def build(domains, opts \\ []) do
    graph = Enum.reduce(List.wrap(domains), %__MODULE__{}, &add_domain(&2, &1))
    graph = add_knobs(graph, opts[:knobs] || Application.get_env(:mana_core, :knobs))
    graph = Enum.reduce(List.wrap(opts[:manifests]), graph, &add_manifest(&2, &1))
    graph = Enum.reduce(opts[:screens] || %{}, graph, fn {verb, files}, graph -> Enum.reduce(files, graph, &screen(&2, verb, &1)) end)
    %{graph | edges: Enum.uniq(graph.edges)}
  end

  defp add_domain(graph, domain) do
    Enum.reduce(Ash.Domain.Info.resources(domain), graph, &add_resource(&2, &1))
  end

  defp add_resource(graph, resource) do
    type = Mana.Entity.type(resource)
    extensions = Spark.extensions(resource)
    graph = node(graph, "resource:#{type}", :resource, %{module: inspect(resource)})

    graph =
      if Mana.Verbs in extensions do
        Enum.reduce(Mana.Verbs.declared(resource), graph, fn verb, graph ->
          id = "verb:#{type}.#{verb.name}"

          graph
          |> node(id, :verb, %{risk: verb.risk, external: verb.external, collection: verb.collection, describe: verb.describe})
          |> edge("resource:#{type}", :offers, id)
          |> then(&if(verb.inverse, do: edge(&1, id, :inverse, "verb:#{type}.#{verb.inverse}"), else: &1))
          |> then(&if(verb.feature, do: &1 |> node("feature:#{verb.feature}", :feature) |> edge("feature:#{verb.feature}", :owns, id), else: &1))
          |> then(&if(verb.knob, do: edge(&1, "knob:#{verb.knob}", :guards, id), else: &1))
          |> then(&if(verb.from, do: edge(&1, "resource:#{Mana.Entity.type(elem(verb.from, 0))}", :offers, id), else: &1))
        end)
      else
        graph
      end

    graph =
      if Mana.Views in extensions do
        Enum.reduce(Mana.Views.declared(resource), graph, fn view, graph ->
          id = "view:#{type}.#{view.name}"
          graph = graph |> node(id, :view, %{entry: view.entry, live: view.live}) |> edge("resource:#{type}", :shows, id)
          if view.entry, do: graph |> node("agent:#{type}.#{view.name}", :agent_entry) |> edge("agent:#{type}.#{view.name}", :opens, id), else: graph
        end)
      else
        graph
      end

    graph =
      if Mana.Flow in extensions do
        Enum.reduce(Mana.Flow.steps(resource), graph, fn step, graph ->
          id = "step:#{type}.#{step.name}"
          graph = graph |> node(id, :flow_step, %{action: step.action}) |> edge("resource:#{type}", :journey, id)
          Enum.reduce(verbs_for(resource, step.action), graph, &edge(&2, id, :done_by, "verb:#{type}.#{&1}"))
        end)
      else
        graph
      end

    graph =
      if Mana.Reconcile in extensions do
        Enum.reduce(Mana.Reconcile.declared(resource), graph, fn rule, graph ->
          id = "rule:#{type}.#{rule.name}"
          graph |> node(id, :rule, %{describe: rule.describe, within: rule.within && Tuple.to_list(rule.within)}) |> edge(id, :about, "resource:#{type}")
        end)
      else
        graph
      end

    if Mana.Entity in extensions do
      Enum.reduce(Mana.Entity.deadlines(resource), graph, fn deadline, graph ->
        id = "deadline:#{type}.#{deadline.name}"
        graph = graph |> node(id, :deadline, %{action: deadline.action}) |> edge("resource:#{type}", :deadline, id)
        Enum.reduce(verbs_for(resource, deadline.action), graph, &edge(&2, id, :performs, "verb:#{type}.#{&1}"))
      end)
    else
      graph
    end
  end

  defp verbs_for(resource, action) do
    if Mana.Verbs in Spark.extensions(resource),
      do: for(verb <- Mana.Verbs.declared(resource), Mana.Verbs.action(verb) == action, do: verb.name),
      else: []
  end

  defp add_knobs(graph, nil), do: graph

  defp add_knobs(graph, module) do
    # `__knobs__/0`, not `Mana.Knobs.declared/1`: the graph needs the
    # declarations, not the stored values.
    knobs = for knob <- module.__knobs__(), do: %{name: knob.name, type: knob.type, feature: knob.opts[:feature], enables: knob.opts[:enables], describe: knob.opts[:describe]}

    Enum.reduce(knobs, graph, fn knob, graph ->
      id = "knob:#{knob.name}"
      graph = node(graph, id, :knob, %{type: knob.type, describe: knob.describe})
      graph = if knob.feature, do: graph |> node("feature:#{knob.feature}", :feature) |> edge(id, :about, "feature:#{knob.feature}"), else: graph

      if knob.enables do
        verbs = for {_, :owns, verb} <- graph.edges, owner <- [knob.enables], feature_owns?(graph, owner, verb), do: verb
        graph = graph |> node("feature:#{knob.enables}", :feature) |> edge(id, :enables, "feature:#{knob.enables}")
        Enum.reduce(verbs, graph, &edge(&2, id, :guards, &1))
      else
        graph
      end
    end)
  end

  # `enables: "checkout"` turns on the verbs of checkout and its sub-features.
  defp feature_owns?(graph, feature, verb) do
    Enum.any?(graph.edges, fn
      {"feature:" <> owner, :owns, ^verb} -> owner == feature or String.starts_with?(owner, feature <> "/")
      _ -> false
    end)
  end

  defp add_manifest(graph, path) do
    manifest = path |> File.read!() |> Jason.decode!()

    Enum.reduce(manifest["moments"] || %{}, graph, fn {name, moment}, graph ->
      id = "moment:#{name}"
      graph = node(graph, id, :moment, %{manifest: path, description: moment["description"]})

      verbs =
        for item <- (moment["steps"] || []) ++ (moment["checks"] || []),
            verb = item["verb"] || verb_target(item["target"]),
            uniq: true,
            do: verb

      Enum.reduce(verbs, graph, &edge(&2, id, :proves, "verb:#{&1}"))
    end)
  end

  defp verb_target("verb:" <> rest), do: rest |> String.split(":") |> hd()
  defp verb_target(_), do: nil

  defp screen(graph, verb, file) do
    id = "screen:#{file}"
    graph |> node(id, :screen) |> edge(id, :renders, "verb:#{verb}")
  end

  defp node(graph, id, kind, data \\ %{}) do
    %{graph | nodes: Map.update(graph.nodes, id, Map.merge(%{id: id, kind: kind}, data), &Map.merge(&1, data))}
  end

  defp edge(graph, from, relation, to), do: %{graph | edges: [{from, relation, to} | graph.edges]}

  # ---------------------------------------------------------------------------

  @doc """
  Answers a canned question:

  - `:verbs_without_moment` — verbs no Moment step or check names;
  - `{:proves, "booking.pay"}` — the Moments that name it;
  - `{:knob, "coupons_enabled"}` — the verbs it guards and the features it is about;
  - `:dead_verbs` — verbs no Moment, agent entry or screen reaches (a deadline
    or flow step performing it counts as reaching it);
  - `{:verb, "booking.pay"}` — everything connected to it.
  """
  def query(graph, :verbs_without_moment) do
    proved = MapSet.new(for {_, :proves, verb} <- graph.edges, do: verb)
    graph |> ids(:verb) |> Enum.reject(&MapSet.member?(proved, &1)) |> Enum.map(&strip/1)
  end

  def query(graph, {:proves, verb}), do: for({from, :proves, "verb:" <> ^verb} <- graph.edges, do: strip(from)) |> Enum.sort()

  def query(graph, {:knob, name}) do
    id = "knob:#{name}"
    %{guards: for({^id, :guards, verb} <- graph.edges, do: strip(verb)) |> Enum.sort(), features: for({^id, rel, f} <- graph.edges, rel in [:about, :enables], do: strip(f)) |> Enum.uniq() |> Enum.sort()}
  end

  def query(graph, :dead_verbs) do
    reached =
      MapSet.new(
        for({_, rel, verb} <- graph.edges, rel in [:proves, :renders, :performs, :done_by], do: verb) ++
          for({"resource:" <> type, :shows, "view:" <> _} <- graph.edges, agent_entry?(graph, type), {"resource:" <> ^type, :offers, verb} <- graph.edges, do: verb)
      )

    graph |> ids(:verb) |> Enum.reject(&MapSet.member?(reached, &1)) |> Enum.map(&strip/1)
  end

  def query(graph, {:verb, verb}) do
    id = "verb:#{verb}"
    for({from, rel, ^id} <- graph.edges, do: %{from: from, relation: rel}) ++ for({^id, rel, to} <- graph.edges, do: %{relation: rel, to: to})
  end

  defp agent_entry?(graph, type), do: Enum.any?(graph.edges, &match?({"agent:" <> _, :opens, "view:" <> _}, &1) and String.starts_with?(elem(&1, 2), "view:#{type}."))

  defp ids(graph, kind), do: for({id, %{kind: ^kind}} <- graph.nodes, do: id) |> Enum.sort()
  defp strip(id), do: id |> String.split(":", parts: 2) |> List.last()

  @doc "The graph as plain JSON-ready maps."
  def to_json(graph) do
    %{
      "nodes" => graph.nodes |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&json_node/1),
      "edges" => graph.edges |> Enum.sort() |> Enum.map(fn {from, rel, to} -> %{"from" => from, "relation" => to_string(rel), "to" => to} end)
    }
  end

  defp json_node(node), do: Map.new(node, fn {k, v} -> {to_string(k), json_value(v)} end)
  defp json_value(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp json_value(v), do: v
end
