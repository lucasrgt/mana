defmodule ManaLint.Check.DirectRepoOnResource do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    run_on_all: true,
    param_defaults: [
      repos: [~r/(^|\.)Repo$/],
      allowed_paths: ManaLint.Code.fixture_paths() ++ [~r"(^|/)priv/repo/migrations/"],
      allowed_modules: []
    ],
    explanations: [
      check: """
      Flags a `Repo.*` or `Ecto.Adapters.SQL.query*` call that reaches a table
      an Ash resource declares (`postgres do table "x" end` anywhere in the
      project): raw SQL naming it, an Ecto query `from(x in "table")`, or the
      resource module used as an Ecto schema. An advisory lock, a `SELECT 1`
      probe or a table no resource owns is left alone.

      Ash owns the rows of its resources. A direct write skips the actions,
      so validations, policies, changes, `Mana.History` and `Mana.Entity`
      announcements do not happen; a direct read skips policies and the
      resource's calculations, and duplicates its schema in SQL that the next
      migration silently breaks.

      Instead, give the operation an action: an atomic update with
      `change atomic_update(:views, expr(views + 1))` run through
      `Ash.bulk_update(query, :count_view, %{}, strategy: :atomic)`, a bulk
      create or destroy, or an aggregate/calculation for a read.
      """,
      params: [
        repos: "Modules that are Ecto repos (regexes or names).",
        allowed_paths: "Paths (regexes or substrings) where direct SQL belongs.",
        allowed_modules:
          "Modules (regexes or substrings of the name) allowed to reach resource tables."
      ]
    ]

  alias ManaLint.Code

  @repo_funs ~w(query query! query_many query_many! all one one! get get! get_by get_by! insert insert!
                insert_all insert_or_update insert_or_update! update update! update_all delete delete!
                delete_all exists? aggregate stream reload reload!)a
  @sql_funs ~w(query query! query_many query_many! stream)a
  @sql_table ~r/\b(?:from|join|update|into|table)\s+(?:only\s+)?(?:"?\w+"?\.)?"?(\w+)"?/i

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    parsed = Enum.map(source_files, &{&1, &1 |> Code.ast() |> Code.modules()})
    tables = tables(parsed)

    for {source_file, modules} <- parsed,
        not Code.listed?(Params.get(params, :allowed_paths, __MODULE__), source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      modules
      |> Enum.reject(&Code.listed?(Params.get(params, :allowed_modules, __MODULE__), &1.name))
      |> Enum.flat_map(&module_issues(&1, tables, params, issue_meta))
      |> append_issues_and_timings(exec)
    end

    :ok
  end

  # table name => the resource declaring it
  defp tables(parsed) do
    for {_, modules} <- parsed,
        module <- modules,
        {:postgres, _, [[do: body]]} <- Code.module_nodes(module),
        {:table, _, [table]} <- Code.nodes(body),
        is_binary(table),
        into: %{},
        do: {table, module.name}
  end

  defp module_issues(module, tables, params, issue_meta) do
    repos = Params.get(params, :repos, __MODULE__)
    resources = tables |> Map.values() |> MapSet.new()

    nodes = Code.module_nodes(module)

    repo_calls =
      for node <- nodes,
          %{} = call <- [Code.call(node, module)],
          repo_call?(call, repos),
          reached = reached(call.args, module, tables, resources),
          reached != nil,
          do: {node, message(call, reached)}

    inside =
      repo_calls |> Enum.flat_map(fn {node, _} -> Code.nodes(elem(node, 2)) end) |> MapSet.new()

    queries =
      for node <- nodes,
          not MapSet.member?(inside, node),
          %{fun: :from, module: m, args: [source | _]} <- [Code.call(node, module)],
          m in [nil, "Ecto.Query"],
          reached = reached([query_source(source)], module, tables, resources),
          reached != nil,
          do: {node, query_message(reached)}

    for {node, message} <- repo_calls ++ queries,
        do: Code.issue(__MODULE__, issue_meta, node, message)
  end

  defp query_source({:in, _, [_, source]}), do: source
  defp query_source(source), do: source

  defp repo_call?(%{module: "Ecto.Adapters.SQL", fun: fun}, _), do: fun in @sql_funs
  defp repo_call?(%{module: nil}, _), do: false

  defp repo_call?(%{module: module, fun: fun}, repos),
    do: fun in @repo_funs and Code.listed?(repos, module)

  defp reached(args, module, tables, resources) do
    args
    |> Code.nodes()
    |> Enum.find_value(fn
      {:@, _, [{name, _, nil}]} -> table_in(module.attributes[name], tables)
      {:__aliases__, _, _} = alias -> resource(Code.resolve(alias, module), resources, tables)
      text when is_binary(text) -> table_in(text, tables)
      _ -> nil
    end)
  end

  defp resource(name, resources, tables) do
    if MapSet.member?(resources, name),
      do: {name, Enum.find_value(tables, fn {t, r} -> r == name && t end)}
  end

  defp table_in(nil, _), do: nil

  defp table_in(text, tables) do
    named = if Map.has_key?(tables, text), do: [text], else: []
    sql = for [_, table] <- Regex.scan(@sql_table, text), do: table

    Enum.find_value(named ++ sql, &(Map.has_key?(tables, &1) && {tables[&1], &1}))
  end

  defp query_message({resource, table}),
    do:
      "An Ecto query on the `#{table}` table of `#{resource}` reads or writes around its actions: " <>
        "no policy, validation, History or announcement. Use an Ash query, action or aggregate."

  defp message(call, {resource, table}),
    do:
      "`#{Code.name(call)}` reaches the `#{table}` table of `#{resource}` around its actions: " <>
        "no validation, policy, History or announcement. Use an action (atomic or bulk) or an aggregate."
end
