defmodule ManaLint.Reads do
  @moduledoc false
  # Which expressions of a function hold the records of an Ash read: the read
  # itself, a variable bound to it, or the records passed through a function
  # that keeps them (Enum.filter, sort, take, a local helper). `reads` narrows
  # what counts as a read: `fresh/0` leaves out `Ash.load`, whose records were
  # already in memory.

  alias ManaLint.Code

  @reads [:read, :read!, :stream!, :load, :load!]
  @keeps [
    :filter,
    :reject,
    :sort,
    :sort_by,
    :take,
    :drop,
    :reverse,
    :uniq,
    :uniq_by,
    :dedup,
    :dedup_by,
    :slice,
    :take_while,
    :drop_while,
    :concat
  ]

  @doc "Reads that query the data layer (not `Ash.load` of records in hand)."
  def fresh, do: [:read, :read!, :stream!]

  @doc "Variables of `body` bound to a read's records: name => the read."
  def vars(body, module, reads \\ @reads),
    do: vars(body, Map.put(module, :reads, reads), %{}, 3)

  defp vars(_, _, vars, 0), do: vars

  defp vars(body, module, vars, rounds) do
    found =
      body
      |> Code.nodes()
      |> Enum.reduce(vars, fn node, acc -> Map.merge(acc, bound(node, module, acc)) end)

    if found == vars, do: vars, else: vars(body, module, found, rounds - 1)
  end

  defp bound({op, _, [pattern, rhs]}, module, vars) when op in [:=, :<-] do
    case holds(rhs, vars, module) do
      nil -> %{}
      read -> pattern |> records_vars() |> Map.new(&{&1, read})
    end
  end

  defp bound({:case, _, [subject, [do: clauses]]}, module, vars) when is_list(clauses) do
    case holds(subject, vars, module) do
      nil ->
        %{}

      read ->
        for {:->, _, [[pattern], _]} <- clauses,
            var <- records_vars(pattern),
            into: %{},
            do: {var, read}
    end
  end

  defp bound(_, _, _), do: %{}

  defp records_vars({:ok, pattern}), do: records_vars(pattern)

  defp records_vars({name, _, context}) when is_atom(name) and is_atom(context),
    do: Code.pattern_vars({name, [], context})

  defp records_vars(_), do: []

  @doc "The read whose records `expr` holds, or nil."
  def source(expr, vars, module, reads \\ @reads),
    do: holds(expr, vars, Map.put(module, :reads, reads))

  defp holds(expr, vars, module) do
    cond do
      Code.calls?(expr, module, "Ash", module.reads) -> expr
      var = var(expr) -> vars[var]
      true -> passed(Code.call(expr, module), vars, module)
    end
  end

  defp var({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp var(_), do: nil

  defp passed(%{module: m, fun: fun, args: [first | rest]}, vars, module)
       when m in ["Enum", "Stream"] do
    if fun in @keeps or (fun == :map and field?(rest)), do: holds(first, vars, module)
  end

  defp passed(%{module: nil, fun: fun, args: [first | _]}, vars, module) do
    if Code.clauses(module, fun) != [], do: holds(first, vars, module)
  end

  defp passed(_, _, _), do: nil

  defp field?([{:&, _, [{{:., _, [{:&, _, [1]}, _]}, _, []}]}]), do: true
  defp field?([{:fn, _, [{:->, _, [[{v, _, c}], {{:., _, [{v, _, c}, _]}, _, []}]}]}]), do: true
  defp field?(_), do: false

  @doc "The code an iteration runs per element: the functions given to `Enum.*`/`Stream.*`, a `for` body."
  def per_element({:for, _, args}, vars, module) when is_list(args) do
    read = Enum.find_value(args, &generator_source(&1, vars, module))
    options = List.last(args)

    if read && Keyword.keyword?(options) && options[:do],
      do: [{options[:do], read}],
      else: []
  end

  def per_element(node, vars, module) do
    with %{module: m, args: [enumerable | rest]} when m in ["Enum", "Stream", "Task"] <-
           Code.call(node, module),
         read when read != nil <- source(enumerable, vars, module) do
      for arg <- rest, Code.function?(arg), do: {arg, read}
    else
      _ -> []
    end
  end

  defp generator_source({:<-, _, [_, rhs]}, vars, module), do: source(rhs, vars, module)
  defp generator_source(_, _, _), do: nil
end
