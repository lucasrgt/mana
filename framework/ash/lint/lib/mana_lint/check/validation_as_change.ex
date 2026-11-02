defmodule ManaLint.Check.ValidationAsChange do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      pure_calls: [
        ~r/^Ash\.Changeset\.(get_|fetch_|changing_|present\?|attribute_present\?|loaded\?)/,
        "Kernel",
        "String",
        "Enum",
        "Map",
        "MapSet",
        "List",
        "Keyword",
        "Tuple",
        "Atom",
        "Integer",
        "Float",
        "Decimal",
        "Regex",
        "Date",
        "DateTime",
        "NaiveDateTime",
        "Time",
        "Access"
      ]
    ],
    explanations: [
      check: """
      Flags `Ash.Changeset.add_error` in a change's `change/3` when the
      condition that leads to it only looks at the changeset — its attributes,
      arguments and data — and not at the result of a query or another
      effect.

      A rule on the input is a validation. Written as a change it runs at the
      wrong time (after changes it should guard, while the changeset is still
      being built), it is not declared, so `Ash.can?`, the contract, the
      generated client's `VerbInput` and `mana capabilities` do not know it,
      and an `atomic` action cannot run it in the database.

      Instead, declare it with the action or in `validations`:

          validate compare(:end_date, greater_than_or_equal_to: :start_date)
          validate attribute_in(:status, [:pending, :accepted])
          validate present([:weekdays])
          validate {MyApp.Validations.Shape, []}   # an Ash.Resource.Validation

      A state transition is a verb's `when` (or AshStateMachine). An error
      that follows a query or an external call stays where it is.
      """,
      params: [
        pure_calls:
          "Calls that only compute (a module, `\"Mod.fun\"`, `{Mod, :fun}` or a regex on `\"Mod.fun\"`); anything else in the condition makes it an effect's result."
      ]
    ]

  alias ManaLint.Code

  @kernel ~w(is_nil is_atom is_binary is_boolean is_integer is_float is_number is_list is_map is_tuple
             is_struct length hd tl elem map_size tuple_size byte_size abs div rem round trunc max min
             not to_string if unless case cond __block__ fn & = {} %{} % <<>> :: @ ^ __aliases__
             __MODULE__ when -> | . .. ..// get_in)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    pure_calls = Params.get(params, :pure_calls, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        "Ash.Resource.Change" in module.uses,
        clause <- Code.clauses(module, :change),
        clause.arity == 3,
        scope = %{module: module, pure_calls: pure_calls, impure: MapSet.new(), state: :none},
        node <- clause.body |> Keyword.get(:do) |> Code.strip_hooks(module) |> errors(scope),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, node, message())
  end

  # The add_error calls decided by conditions on the changeset alone. `state`
  # is :pure under such a condition, :blocked under one that is not (the
  # result of a query or a call), :none outside any.
  defp errors({:__block__, _, exprs}, scope), do: block(exprs, scope)

  defp errors({branch, _, [condition, options]}, scope)
       when branch in [:if, :unless] and is_list(options) do
    inner = decide(scope, pure?(condition, scope))
    errors(condition, scope) ++ Enum.flat_map(Keyword.values(options), &errors(&1, inner))
  end

  defp errors({:cond, _, [[do: clauses]]}, scope) do
    for {:->, _, [[condition], body]} <- clauses,
        node <- errors(body, decide(scope, pure?(condition, scope))),
        do: node
  end

  defp errors({:case, _, [subject, [do: clauses]]}, scope) do
    pure = pure?(subject, scope)
    inner = decide(scope, pure)

    for {:->, _, [patterns, body]} <- clauses,
        node <- errors(body, if(pure, do: inner, else: impure(inner, patterns))),
        do: node
  end

  defp errors({:with, _, args}, scope) do
    {clauses, options} = Enum.split_with(args, &(not is_list(&1)))
    rhs = for {:<-, _, [_, rhs]} <- clauses, do: rhs
    patterns = for {:<-, _, [pattern, _]} <- clauses, do: pattern
    pure = Enum.all?(rhs, &pure?(&1, scope))
    inner = if pure, do: decide(scope, true), else: impure(decide(scope, false), patterns)
    options |> List.flatten() |> Keyword.values() |> Enum.flat_map(&errors(&1, inner))
  end

  defp errors(node, %{state: :pure} = scope) do
    if Code.calls?(node, scope.module, "Ash.Changeset", [:add_error]),
      do: [node | children(node, scope)],
      else: children(node, scope)
  end

  defp errors(node, scope), do: children(node, scope)

  defp children({_, _, args}, scope) when is_list(args),
    do: Enum.flat_map(args, &errors(&1, scope))

  defp children(list, scope) when is_list(list), do: Enum.flat_map(list, &errors(&1, scope))
  defp children({left, right}, scope), do: errors(left, scope) ++ errors(right, scope)
  defp children(_, _), do: []

  defp decide(%{state: :blocked} = scope, _), do: scope
  defp decide(scope, true), do: %{scope | state: :pure}
  defp decide(scope, false), do: %{scope | state: :blocked}

  defp block([], _), do: []

  defp block([{:=, _, [pattern, rhs]} = expr | rest], scope) do
    after_binding = if pure?(rhs, scope), do: scope, else: impure(scope, [pattern])
    errors(expr, scope) ++ block(rest, after_binding)
  end

  defp block([expr | rest], scope), do: errors(expr, scope) ++ block(rest, scope)

  defp impure(scope, patterns),
    do: %{scope | impure: MapSet.union(scope.impure, MapSet.new(Code.pattern_vars(patterns)))}

  defp pure?(expr, scope, depth \\ 2) do
    expr
    |> Code.nodes()
    |> Enum.all?(&pure_node?(&1, scope, depth))
  end

  defp pure_node?({name, _, context}, scope, _) when is_atom(name) and is_atom(context),
    do: not MapSet.member?(scope.impure, name)

  defp pure_node?({{:., _, [{name, _, context}]}, _, _}, scope, _)
       when is_atom(name) and is_atom(context),
       do: not MapSet.member?(scope.impure, name)

  defp pure_node?(node, scope, depth) do
    case Code.call(node, scope.module) do
      nil -> true
      %{module: nil, fun: fun, args: args} -> local_pure?(fun, length(args), scope, depth)
      %{module: module, fun: fun} -> Code.matches?(scope.pure_calls, module, fun)
    end
  end

  defp local_pure?(fun, arity, scope, depth) do
    cond do
      fun in @kernel or Macro.operator?(fun, arity) -> true
      depth == 0 -> false
      true -> defined_pure?(Code.clauses(scope.module, fun), scope, depth)
    end
  end

  defp defined_pure?([], _, _), do: false

  defp defined_pure?(clauses, scope, depth),
    do: Enum.all?(clauses, &pure?(&1.body, %{scope | impure: MapSet.new()}, depth - 1))

  defp message,
    do:
      "`add_error` in `change/3` on a condition of the changeset alone: a validation written as a change. " <>
        "Declare it (`validate compare/attribute_in/present` or an `Ash.Resource.Validation`)."
end
