defmodule Moments.ActionGraph do
  @moduledoc """
  Which Ash actions a backend file can change, so `moments affected` can
  choose Moments by effect. `Moments.BackendGraph` exports it as
  `backendGraph.actions`:

  - `effects`: each file that only create, update and destroy actions reach,
    through their changes, validations, manual implementations and notifiers
    and the modules those call, mapped to those actions (`MyApp.Booking.pay`).
    A file anything else reaches (a resource's own file, a read's preparation,
    a generic action, a calculation, a policy check, a recipe, a controller)
    is not listed, and keeps the file graph's selection.
  - `verbs`: each verb a Moment's step names, mapped to the action it runs.
  - `recipes`: each `Moments.RecipeSet` recipe, mapped to the resources its
    set's module reaches.

  It reads `Ash.Resource.Info` and the xref file graph at export time. A
  module a resource names as a change and also calls from its own body is not
  told apart. On any error it is `unavailable`, with the reason printed, and
  selection stays with the file graph.
  """
  alias Ash.Resource.Info

  # mana_core is optional: verbs resolve only when the project has it.
  @compile {:no_warn_undefined, [Mana.Entity, Mana.Verbs]}
  @mutations [:create, :update, :destroy]
  @bound 20_000

  @doc """
  The action map for `manifest`, from the xref `graph` (file => dependencies,
  relative to the project). `portable` turns a file into the manifest's path.
  `modules:` replaces the project's own modules (resources and recipe sets).
  """
  def build(manifest, graph, portable, opts \\ []) do
    modules = Keyword.get_lazy(opts, :modules, &project_modules/0)
    if length(modules) > 5 * @bound, do: raise(ArgumentError, "module bound exceeded")
    resources = Enum.filter(modules, &resource?/1)
    # A file may declare several resources.
    resource_files = Enum.group_by(resources, &file!(&1, graph))
    walk = &closure(&1, graph, resource_files)
    actions = actions(resources, graph, walk)

    %{
      "version" => 1,
      "status" => "available",
      "engine" => "ash-resource-info+mix-xref",
      "effects" => effects(actions, resources, graph, resource_files, walk, portable),
      "verbs" => verbs(manifest, resources),
      "recipes" => recipes(modules, graph, resource_files, walk)
    }
  rescue
    # Effects only sharpen selection; without them the file graph decides.
    error ->
      IO.warn("Moments action graph is unavailable: " <> Exception.message(error), [])
      %{"version" => 1, "status" => "unavailable"}
  end

  defp project_modules do
    app = Keyword.fetch!(Mix.Project.config(), :app)
    _ = Application.load(app)
    Application.spec(app, :modules) || raise(ArgumentError, "the project's modules are unknown")
  end

  defp resource?(module), do: Code.ensure_loaded?(module) and Info.resource?(module)

  defp actions(resources, graph, walk) do
    actions =
      for resource <- resources, action <- Info.actions(resource) do
        entries = resource |> entries(action) |> files(graph)

        %{
          id: "#{inspect(resource)}.#{action.name}",
          mutation?: action.type in @mutations,
          resource: file!(resource, graph),
          entries: entries,
          files: walk.(entries)
        }
      end

    if length(actions) > @bound, do: raise(ArgumentError, "action bound exceeded")
    actions
  end

  # What an action runs besides its resource's own file.
  defp entries(resource, %{type: type} = action) when type in @mutations do
    [
      Info.action_changes(resource, action),
      Info.validations(resource, type),
      action.manual,
      action.notifiers,
      Info.notifiers(resource)
    ]
  end

  defp entries(resource, %{type: :read} = action),
    do: [Info.preparations(resource, :read), action.preparations, action.manual]

  defp entries(resource, action),
    do: [Info.preparations(resource, :action), action.preparations, action.run]

  # What a resource runs for any read: calculations and policy checks.
  defp shared(resource) do
    policies = if Code.ensure_loaded?(Ash.Policy.Info), do: Ash.Policy.Info.policies(resource)
    [Info.calculations(resource), policies]
  end

  # A file only mutations reach, never through anything else, is an effect of
  # those mutations. The edges from a resource to its mutations' entries are
  # cut; whatever is still reachable from any other file is not an effect.
  defp effects(actions, resources, graph, resource_files, walk, portable) do
    {mutations, others} = Enum.split_with(actions, & &1.mutation?)
    shared = resources |> Enum.flat_map(&shared/1) |> files(graph) |> walk.()
    other = Enum.reduce(others, shared, &MapSet.union(&2, &1.files))

    private =
      mutations
      |> Enum.reduce(MapSet.new(), &MapSet.union(&2, &1.files))
      |> MapSet.difference(other)
      |> Enum.reject(&Map.has_key?(resource_files, &1))
      |> MapSet.new()

    cut =
      for action <- mutations,
          entry <- action.entries,
          MapSet.member?(private, entry),
          into: MapSet.new(),
          do: {action.resource, entry}

    reached = reach(Enum.reject(Map.keys(graph), &MapSet.member?(private, &1)), graph, cut)

    for file <- private, !MapSet.member?(reached, file), into: %{} do
      ids = for action <- mutations, MapSet.member?(action.files, file), do: action.id
      {portable.(file), Enum.sort(ids)}
    end
  end

  defp verbs(manifest, resources) do
    named =
      for {_name, scene} <- manifest["moments"],
          step <- scene["steps"] || [],
          verb = step["verb"],
          uniq: true,
          do: verb

    if named != [] and Code.ensure_loaded?(Mana.Verbs) and Code.ensure_loaded?(Mana.Entity) do
      verbed = Enum.filter(resources, &(Mana.Verbs in Spark.extensions(&1)))
      for verb <- named, id = verb_action(verb, verbed), into: %{}, do: {verb, id}
    else
      %{}
    end
  end

  defp verb_action(verb, resources) do
    [type, name] = String.split(verb, ".", parts: 2)

    found =
      for resource <- resources,
          Mana.Entity.type(resource) == type,
          declared <- Mana.Verbs.declared(resource),
          to_string(declared.name) == name,
          do: "#{inspect(resource)}.#{Mana.Verbs.action(declared)}"

    # An ambiguous verb names no action; its Moment stays selected.
    case found do
      [id] -> id
      _ -> nil
    end
  end

  # The resources a recipe set's module reaches, for every recipe it names.
  defp recipes(modules, graph, resource_files, walk) do
    sets =
      Enum.filter(modules, &(Code.ensure_loaded?(&1) and function_exported?(&1, :__recipes__, 0)))

    recipes =
      for set <- sets,
          reached = reached_resources(set, graph, resource_files, walk),
          name <- Map.keys(set.__recipes__()),
          into: %{},
          do: {name, reached}

    if map_size(recipes) > @bound, do: raise(ArgumentError, "recipe bound exceeded")
    recipes
  end

  defp reached_resources(set, graph, resource_files, walk) do
    for file <- walk.([file!(set, graph)]),
        resource <- Map.get(resource_files, file, []),
        uniq: true,
        do: inspect(resource)
  end

  # Every file the entries reach. A resource's file is kept but not expanded:
  # the actions it runs are told apart by their own entries.
  defp closure(entries, graph, resource_files) do
    expand = fn file -> if Map.has_key?(resource_files, file), do: [], else: graph[file] end
    traverse(entries, MapSet.new(), expand)
  end

  defp reach(roots, graph, cut) do
    traverse(roots, MapSet.new(), fn file ->
      Enum.reject(graph[file], &MapSet.member?(cut, {file, &1}))
    end)
  end

  defp traverse([], seen, _expand), do: seen

  defp traverse([file | rest], seen, expand) do
    if MapSet.member?(seen, file),
      do: traverse(rest, seen, expand),
      else: traverse(expand.(file) ++ rest, MapSet.put(seen, file), expand)
  end

  # The project files of the modules a declaration names, anywhere in it;
  # modules of dependencies and anonymous functions have none.
  defp files(declarations, graph) do
    declarations
    |> modules(8)
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(file(&1, graph)))
    |> Enum.uniq()
  end

  defp modules(_value, 0), do: []

  defp modules(value, depth) when is_atom(value) do
    if String.starts_with?(Atom.to_string(value), "Elixir."),
      do: [value],
      else: modules([], depth)
  end

  defp modules(value, depth) when is_list(value),
    do: Enum.flat_map(value, &modules(&1, depth - 1))

  defp modules(value, depth) when is_tuple(value), do: modules(Tuple.to_list(value), depth)

  defp modules(%_{} = value, depth),
    do: value |> Map.from_struct() |> Map.delete(:__spark_metadata__) |> modules(depth)

  defp modules(value, depth) when is_map(value), do: modules(Map.values(value), depth)
  defp modules(_value, _depth), do: []

  defp file(module, graph) do
    if Code.ensure_loaded?(module) do
      file = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(File.cwd!())
      if Map.has_key?(graph, file), do: file
    end
  end

  defp file!(module, graph),
    do:
      file(module, graph) ||
        raise(ArgumentError, "#{inspect(module)} is outside the compiled project")
end
