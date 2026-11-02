defmodule ManaLint.Check.InMemoryFilterAfterRead do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    run_on_all: true,
    param_defaults: [allowed_paths: ManaLint.Code.fixture_paths(), non_trivial: false],
    explanations: [
      check: """
      Flags the records of an Ash read filtered in Elixir — `Enum.filter`,
      `reject`, `find`, `split_with` over `Ash.read!` or a variable bound to
      it — when the predicate is a plain comparison of the record's fields
      (`& &1.status == :live`, `fn p -> p.city == city end`, or a function,
      in this module or another, whose clauses only match fields and compare
      them: `accepts?(%{kinds: []}, _), do: true` and `accepts?(%{kinds:
      kinds}, kind), do: kind in kinds`).

      The database sends every row, the application throws most away, and the
      page sizes, counts and offsets computed on the result are wrong unless
      the filter runs before them. A comparison the query could have done
      costs a full scan of the read's results on every request.

      Instead, put the comparison in the query, where it can use an index and
      paginate:

          Property
          |> Ash.Query.filter(^vehicle in accepted_vehicles and status == :live)
          |> Ash.read!()

      For text matching, use `Mana.Search`; for a rule used in several reads,
      an `expr` calculation or a read action's `filter`.
      """,
      params: [
        allowed_paths:
          "Paths (regexes or substrings) where filtering read records is fine (tests, fixtures).",
        non_trivial:
          "Also flag predicates that are not a plain field comparison (worth a look, not always movable)."
      ]
    ]

  alias ManaLint.{Code, Reads}

  @filters ~w(filter reject find split_with)a
  @comparisons [:==, :!=, :===, :!==, :<, :>, :<=, :>=, :in]
  @booleans [:and, :or, :&&, :||]
  @leaf_forms [:@, :{}, :%{}, :%, :__aliases__, :^, :&, :., :.., :"::", :<<>>, :|]

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    parsed = Enum.map(source_files, &{&1, &1 |> Code.ast() |> Code.modules()})
    index = index(parsed)
    allowed = Params.get(params, :allowed_paths, __MODULE__)
    non_trivial = Params.get(params, :non_trivial, __MODULE__)

    for {source_file, modules} <- parsed, not Code.listed?(allowed, source_file.filename) do
      issue_meta = IssueMeta.for(source_file, params)

      for module <- modules,
          clause <- Code.defs(module),
          {node, line, plain} <- filters(clause, module, index),
          plain or non_trivial do
        Code.issue(__MODULE__, issue_meta, node, message(Code.call(node, module), line, plain))
      end
      |> append_issues_and_timings(exec)
    end

    :ok
  end

  defp index(parsed) do
    for {_, modules} <- parsed, module <- modules, clause <- Code.defs(module), reduce: %{} do
      index -> Map.update(index, {module.name, clause.name}, [clause], &(&1 ++ [clause]))
    end
  end

  defp filters(clause, module, index) do
    vars = Reads.vars(clause.body, module, Reads.fresh())

    for node <- Code.nodes(clause.body),
        %{module: "Enum", fun: fun, args: [records, predicate]} <- [Code.call(node, module)],
        fun in @filters,
        read = Reads.source(records, vars, module, Reads.fresh()),
        read != nil,
        do: {node, Code.line(read), plain?(predicate, module, index)}
  end

  defp plain?({:fn, _, [{:->, _, [[pattern], body]}]}, _, _),
    do: comparison?(body, element(pattern))

  defp plain?({:&, _, [body]} = capture, module, index) do
    case delegate(capture, body, module, index) do
      {clauses, position} -> Enum.all?(clauses, &plain_clause?(&1, position))
      nil -> comparison?(body, [])
    end
  end

  defp plain?(_, _, _), do: false

  # A capture that only forwards the element to a one-clause function.
  defp delegate(capture, body, module, index) do
    {target, args} =
      case {Code.local_capture(capture), Code.call(body, module)} do
        {{name, _}, _} -> {{module.name, name}, [{:&, [], [1]}]}
        {nil, %{module: nil, fun: :/, args: [remote, 1]}} -> remote_capture(remote, module)
        {nil, %{module: nil, fun: fun, args: args}} -> {{module.name, fun}, args}
        {nil, %{module: mod, fun: fun, args: args}} -> {{mod, fun}, args}
        _ -> {nil, []}
      end

    position = Enum.find_index(args, &match?({:&, _, [1]}, &1))

    case Map.get(index, target, []) do
      [_ | _] = clauses when position != nil ->
        if Enum.all?(clauses, &(length(&1.args) == length(args))), do: {clauses, position}

      _ ->
        nil
    end
  end

  defp remote_capture(remote, module) do
    case Code.call(remote, module) do
      %{module: mod, fun: fun} when mod != nil -> {{mod, fun}, [{:&, [], [1]}]}
      _ -> {nil, []}
    end
  end

  # A clause whose body is a literal answer (its head did the matching) or a
  # field comparison.
  defp plain_clause?(clause, position) do
    case Keyword.get(clause.body, :do) do
      answer when is_boolean(answer) -> true
      body -> comparison?(body, element(Enum.at(clause.args, position)))
    end
  end

  defp element(pattern), do: Code.pattern_vars(pattern)

  defp comparison?({op, _, [left, right]}, element) when op in @comparisons,
    do:
      leaf?(left) and leaf?(right) and (of_element?(left, element) or of_element?(right, element))

  defp comparison?({op, _, [left, right]}, element) when op in @booleans,
    do: comparison?(left, element) and comparison?(right, element)

  defp comparison?({op, _, [operand]}, element) when op in [:not, :!, :is_nil],
    do:
      comparison?(operand, element) or
        (op == :is_nil and leaf?(operand) and of_element?(operand, element))

  defp comparison?(field, element), do: field?(field) and of_element?(field, element)

  defp field?({{:., _, [_, field]}, meta, []}) when is_atom(field), do: meta[:no_parens] == true
  defp field?(_), do: false

  defp leaf?(expr) do
    expr
    |> Code.nodes()
    |> Enum.all?(fn node ->
      case Code.call(node, nil) do
        nil -> true
        %{module: nil, fun: fun} -> fun in @leaf_forms
        _ -> field?(node)
      end
    end)
  end

  defp of_element?(expr, element) do
    Code.find(expr, &match?({:&, _, [1]}, &1)) != [] or Code.mentions?(expr, element)
  end

  defp message(call, line, true),
    do:
      "`#{Code.name(call)}` keeps records of the read on line #{line} by a field comparison in Elixir: " <>
        "every row is loaded to keep some. Put the comparison in the query (`Ash.Query.filter`)."

  defp message(call, line, false),
    do:
      "`#{Code.name(call)}` filters records of the read on line #{line} in Elixir. " <>
        "If the rule can be an `expr` (or `Mana.Search`), move it into the query."
end
