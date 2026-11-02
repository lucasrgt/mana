defmodule Mana.Upgrade.TimedRules do
  @moduledoc """
  A reconcile rule whose `holds:` only asks whether a timestamp plus a fixed
  duration is still ahead of now becomes a timed rule:

      desired :accepted_resolves, "...", scope: expr(status == :accepted),
        holds: {MyApp.Bookings, :recent?}

      def recent?(booking),
        do: DateTime.compare(DateTime.add(booking.accepted_at, 15, :minute), DateTime.utc_now()) == :gt

      # the rule becomes
      desired :accepted_resolves, "...", scope: expr(status == :accepted),
        within: {15, :minute}, since: :accepted_at

  The function must be found in the files given, be the only clause of a
  public arity-1 function with a plain variable argument, and its body one of
  (`DateTime` or `NaiveDateTime`, `n` a positive integer, `unit` `:second`,
  `:minute`, `:hour` or `:day`, `:second` when left out):

    * `compare(add(r.field, n, unit), utc_now()) == :gt`
    * `compare(utc_now(), add(r.field, n, unit)) == :lt`
    * `after?(add(r.field, n, unit), utc_now())`
    * `before?(utc_now(), add(r.field, n, unit))`
    * `diff(utc_now(), r.field, unit) < n`

  Anything else, and a rule that already has `within:` or `since:`, is left
  as written and reported. The rewritten rule differs only at the boundary
  second and for a record without the timestamp, which `Mana.Reconcile`
  reports as diverging where the function would have raised. The function
  itself stays: delete it once nothing else calls it.
  """
  @behaviour Mana.Upgrade

  import Mana.Upgrade.Source

  @clocks [:DateTime, :NaiveDateTime]
  @units [:second, :minute, :hour, :day]
  @not_literal "holds is not a {Module, :function} literal"

  @impl true
  def rewrite(sources, _opts) do
    functions =
      for {_, source} <- sources,
          {:ok, ast} <- [parse(source)],
          module <- modules(statements(ast)),
          {key, def} <- defs(module),
          reduce: %{} do
        functions -> Map.update(functions, key, [def], &(&1 ++ [def]))
      end

    edit(sources, fn ast ->
      for {module, rule} <- rules(ast), result = rule(rule, module, functions), result, do: result
    end)
  end

  # Each module defined among `statements` (nested ones too) with its full
  # name, body and the aliases in scope.
  defp modules(statements, parent \\ nil, inherited \\ %{}) do
    for {:defmodule, _, [{:__aliases__, _, parts}, body]} <- statements,
        Enum.all?(parts, &is_atom/1),
        module = Module.concat(List.wrap(parent) ++ parts),
        inner = statements(do_body([body])),
        aliases = Map.merge(inherited, aliases(inner)),
        found <- [
          %{name: module, body: inner, aliases: aliases} | modules(inner, module, aliases)
        ],
        do: found
  end

  defp aliases(statements) do
    for {:alias, _, [{:__aliases__, _, parts} | rest]} <- statements,
        Enum.all?(parts, &is_atom/1),
        into: %{} do
      as =
        case keywords(rest) do
          [{:as, _, {:__aliases__, _, [as]}} | _] -> as
          _ -> List.last(parts)
        end

      {as, Module.concat(parts)}
    end
  end

  defp defs(%{name: module, body: body}) do
    for {:def, _, [head | _]} = def <- body,
        {fun, arity} <- [signature(head)],
        do: {{module, fun, arity}, def}
  end

  defp signature({:when, _, [head | _]}), do: signature(head)
  defp signature({fun, _, args}) when is_atom(fun) and is_list(args), do: {fun, length(args)}
  defp signature(_), do: {nil, 0}

  # Each `desired` of each `reconcile` section, with the module it is in.
  defp rules(ast) do
    for module <- modules(statements(ast)),
        {:reconcile, _, args} <- module.body,
        is_list(args),
        {:desired, _, _} = rule <- calls(statements(do_body(args)), :desired),
        do: {module, rule}
  end

  defp rule({:desired, _, args} = rule, module, functions) do
    options = keywords(args)
    timed? = Enum.any?(options, &(elem(&1, 0) in [:within, :since]))

    case List.keyfind(options, :holds, 0) do
      nil -> nil
      _ when timed? -> skip(rule, "already has within:/since:")
      {:holds, key, value} -> holds(rule, key, value, module, functions)
    end
  end

  defp holds(rule, key, value, module, functions) do
    with {:ok, target, fun} <- target(literal(value), module),
         {:ok, def} <- only_clause(functions, target, fun),
         {:ok, {amount, unit, field}} <- timed(def) do
      {:patch,
       replace(key, value, "within: {#{amount}, #{inspect(unit)}}, since: #{inspect(field)}")}
    else
      {:error, reason} -> skip(rule, reason)
    end
  end

  defp skip({:desired, _, [name | _]} = rule, reason),
    do: {:skip, %{line: line(rule), reason: "desired #{inspect(literal(name))}: #{reason}"}}

  defp target({{:__MODULE__, _, _}, fun}, module), do: target_fun(module.name, fun)

  defp target({{:__aliases__, _, [first | rest] = parts}, fun}, module) do
    if Enum.all?(parts, &is_atom/1),
      do: target_fun(Module.concat([Map.get(module.aliases, first, first) | rest]), fun),
      else: {:error, @not_literal}
  end

  defp target(_, _), do: {:error, @not_literal}

  defp target_fun(target, fun) do
    case literal(fun) do
      fun when is_atom(fun) -> {:ok, target, fun}
      _ -> {:error, @not_literal}
    end
  end

  defp only_clause(functions, target, fun) do
    case functions[{target, fun, 1}] do
      nil -> {:error, "#{label(target, fun)} has no def in the files given"}
      [def] -> {:ok, def}
      _ -> {:error, "#{label(target, fun)} has more than one clause"}
    end
  end

  defp label(target, fun), do: "#{inspect(target)}.#{fun}/1"

  defp timed({:def, _, [{_, _, [{var, _, context}]}, body]})
       when is_atom(var) and is_atom(context) do
    case [body] |> do_body() |> statements() do
      [expression] -> match(plain(expression), var)
      _ -> {:error, "its body is more than one expression"}
    end
  end

  defp timed(_), do: {:error, "it has a guard or an argument pattern"}

  # The AST without metadata and literal wrappers, to match on its shape.
  defp plain(ast) do
    Macro.prewalk(ast, fn
      {:__block__, _, [_]} = node -> plain_literal(node)
      {form, _, args} -> {form, [], args}
      other -> other
    end)
  end

  defp plain_literal(node) do
    case literal(node) do
      ^node -> {:__block__, [], elem(node, 2)}
      value -> value
    end
  end

  defp match({:==, [], [compare, :gt]}, var) do
    with {clock, :compare, [deadline, now]} <- remote(compare),
         true <- now?(now, clock),
         do: deadline(deadline, clock, var),
         else: (_ -> not_timed())
  end

  defp match({:==, [], [compare, :lt]}, var) do
    with {clock, :compare, [now, deadline]} <- remote(compare),
         true <- now?(now, clock),
         do: deadline(deadline, clock, var),
         else: (_ -> not_timed())
  end

  defp match({:<, [], [diff, amount]}, var) when is_integer(amount) and amount > 0 do
    case remote(diff) do
      {clock, :diff, [now, at | unit]} ->
        if now?(now, clock), do: window(at, amount, unit, var), else: not_timed()

      _ ->
        not_timed()
    end
  end

  defp match(call, var) do
    case remote(call) do
      {clock, :after?, [deadline, now]} ->
        if now?(now, clock), do: deadline(deadline, clock, var), else: not_timed()

      {clock, :before?, [now, deadline]} ->
        if now?(now, clock), do: deadline(deadline, clock, var), else: not_timed()

      _ ->
        not_timed()
    end
  end

  defp remote({{:., [], [{:__aliases__, [], [clock]}, fun]}, [], args}) when clock in @clocks,
    do: {clock, fun, args}

  defp remote(_), do: nil

  defp now?(now, clock), do: remote(now) == {clock, :utc_now, []}

  defp deadline(deadline, clock, var) do
    case remote(deadline) do
      {^clock, :add, [at, amount | unit]} when is_integer(amount) and amount > 0 ->
        window(at, amount, unit, var)

      _ ->
        not_timed()
    end
  end

  defp window({{:., [], [{var, [], context}, field]}, [], []}, amount, unit, var)
       when is_atom(field) and is_atom(context) do
    case unit do
      [] -> {:ok, {amount, :second, field}}
      [unit] when unit in @units -> {:ok, {amount, unit, field}}
      _ -> not_timed()
    end
  end

  defp window(_, _, _, _), do: not_timed()

  defp not_timed, do: {:error, "holds is not a timestamp plus a fixed duration compared with now"}
end
