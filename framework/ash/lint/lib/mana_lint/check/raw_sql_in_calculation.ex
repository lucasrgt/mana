defmodule ManaLint.Check.RawSqlInCalculation do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [repos: [~r/(^|\.)Repo$/]],
    explanations: [
      check: """
      Flags, inside a calculation (`calculate/3` of an `Ash.Resource.Calculation`,
      the functions it calls, or an inline `calculate :x, :type, fn ... end`):

      - a `Repo.*` or `Ecto.Adapters.SQL.*` call — raw SQL;
      - an `Ash.get/read/read_one/exists?/count/aggregate/load` run per record
        (inside `Enum.*`, `Stream.*` or `for`, or in a function called from
        there) — a query per record.

      Raw SQL in a calculation bypasses the read's policies and tenancy and
      cannot be filtered, sorted or loaded by Ash: it only works where it is
      loaded, and duplicates table and column names a migration can change. A
      query per record turns a page of 25 into 26 queries.

      Instead, express it so it runs in the read's query: an aggregate
      (`count :unread, :messages, filter: expr(is_nil(read_at))`, `first
      :preview, :messages, :body, sort: [inserted_at: :desc]`), an
      `expr(...)` calculation, or `load/3` plus one batched read for all the
      records the calculation receives.
      """,
      params: [repos: "Modules that are Ecto repos (regexes or names)."]
    ]

  alias ManaLint.Code

  @reads ~w(get get! read read! read_one read_one! exists exists? count count! aggregate aggregate!
            load load! calculate calculate!)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    repos = Params.get(params, :repos, __MODULE__)

    source_file
    |> Code.ast()
    |> Code.modules()
    |> Enum.flat_map(&module_issues(&1, repos))
    |> Enum.uniq()
    |> Enum.map(fn {node, message} -> Code.issue(__MODULE__, issue_meta, node, message) end)
  end

  defp module_issues(module, repos) do
    inline =
      for {:calculate, _, [_name, _type, function | _]} <- Code.module_nodes(module),
          Code.function?(function),
          body <- Code.function_bodies(function),
          issue <- issues(body, module, repos),
          do: issue

    if "Ash.Resource.Calculation" in module.uses do
      bodies = for clause <- Code.clauses(module, :calculate), do: clause.body
      inline ++ Enum.flat_map(bodies ++ reachable(module, bodies), &issues(&1, module, repos))
    else
      inline
    end
  end

  # The module's functions a calculation body calls, transitively.
  defp reachable(module, bodies, seen \\ MapSet.new([:calculate])) do
    called =
      for body <- bodies,
          node <- Code.nodes(body),
          name <- local_names(node, module),
          not MapSet.member?(seen, name),
          uniq: true,
          do: name

    case called do
      [] ->
        []

      names ->
        found = for name <- names, clause <- Code.clauses(module, name), do: clause.body
        found ++ reachable(module, found, MapSet.union(seen, MapSet.new(names)))
    end
  end

  defp local_names(node, module) do
    case Code.local_capture(node) || Code.call(node, module) do
      {name, _} -> [name]
      %{module: nil, fun: name} -> [name]
      _ -> []
    end
  end

  defp issues(body, module, repos) do
    raw =
      for node <- Code.nodes(body),
          %{} = call <- [Code.call(node, module)],
          raw?(call, repos),
          do: {node, raw_message(call)}

    raw ++ per_record(body, module)
  end

  defp raw?(%{module: "Ecto.Adapters.SQL"}, _), do: true
  defp raw?(%{module: nil}, _), do: false
  defp raw?(%{module: module}, repos), do: Code.listed?(repos, module)

  defp per_record(body, module) do
    for node <- Code.nodes(body),
        each <- per_record_code(node, module),
        inner <- Code.nodes([each | local_bodies(each, module)]),
        Code.calls?(inner, module, "Ash", @reads),
        uniq: true,
        do: {inner, read_message(Code.call(inner, module))}
  end

  defp per_record_code({:for, _, args}, _),
    do: args |> List.last() |> List.wrap() |> Keyword.values()

  defp per_record_code(node, module) do
    case Code.call(node, module) do
      %{module: m, args: args} when m in ["Enum", "Stream"] ->
        Enum.filter(args, &Code.function?/1)

      _ ->
        []
    end
  end

  defp local_bodies(ast, module) do
    for node <- Code.nodes(ast),
        name <- local_names(node, module),
        clause <- Code.clauses(module, name),
        do: clause.body
  end

  defp raw_message(call),
    do:
      "`#{Code.name(call)}` in a calculation: raw SQL skips the read's policies and cannot be filtered or sorted. " <>
        "Use an aggregate or an `expr` calculation."

  defp read_message(call),
    do:
      "`#{Code.name(call)}` runs once per record in a calculation. " <>
        "Load it with the read (aggregate, relationship, `expr`) or batch one read for all records."
end
