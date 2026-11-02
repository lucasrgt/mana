defmodule ManaLint.Check.PersistentTermHotWrite do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      time_calls: [
        ~r/^System\.(monotonic_time|os_time|system_time)$/,
        ~r/^(DateTime|NaiveDateTime|Date|Time)\.utc_(now|today)$/,
        ~r/^:(os|erlang)\.(system_time|monotonic_time|timestamp)$/
      ],
      time_names:
        ~r/^(now|today|\w+_at|\w*_?time|expires?(_\w+)?|expiry|deadline|ttl(_\w+)?|stamp|timestamp)$/
    ],
    explanations: [
      check: """
      Flags `:persistent_term.put/2` refreshed on a timer or a TTL: a put
      whose value carries a time (`{value, now}`, `{now + max_age, keys}`) or
      that sits in a branch deciding on one (`if expired?(at, now)`).

      `:persistent_term` is built for values written once and read forever.
      Every `put` (and erase) of an existing key makes the VM scan every
      process for references to the old value — a global garbage collection
      pass — so a cache refreshed every few seconds, or per key, stalls the
      whole node as it grows. Concurrent misses also all refresh at once.

      Instead, for a value that expires: an ETS table owned by a supervised
      process (`read_concurrency: true`, `:ets.insert/2` with the expiry in
      the tuple), or a cache library; refresh from one process (a GenServer
      timer) rather than in every caller's read path. Keep `:persistent_term`
      for configuration loaded once at boot or lazily once per key.
      """,
      params: [
        time_calls:
          "Calls that read the clock (a module, `\"Mod.fun\"`, `{Mod, :fun}` or a regex on `\"Mod.fun\"`).",
        time_names: "Variables (and parameters) whose name says they hold a time."
      ]
    ]

  alias ManaLint.Code

  @branches [:if, :unless, :case, :cond]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    time_calls = Params.get(params, :time_calls, __MODULE__)
    time_names = Params.get(params, :time_names, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        clause <- Code.defs(module),
        scope = %{
          module: module,
          calls: time_calls,
          names: time_names,
          vars: time_vars(clause, module, time_calls, time_names)
        },
        node <- puts(clause.body, scope, false),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, node, message())
  end

  defp time_vars(clause, module, calls, names) do
    scope = %{module: module, calls: calls, names: names, vars: MapSet.new()}

    for {:=, _, [pattern, rhs]} <- Code.nodes(clause.body),
        timed?(rhs, scope),
        var <- Code.pattern_vars(pattern),
        into: MapSet.new(),
        do: var
  end

  # The puts under a decision on a time, or whose value holds one.
  defp puts(node, scope, timed) do
    cond do
      put?(node, scope) ->
        if timed or timed?(List.last(elem(node, 2)), scope), do: [node], else: []

      branch?(node) ->
        branch_puts(node, scope, timed)

      true ->
        node |> children() |> Enum.flat_map(&puts(&1, scope, timed))
    end
  end

  defp branch?({branch, _, [_ | _]}) when branch in @branches, do: true
  defp branch?({:->, _, [_, _]}), do: true
  defp branch?(_), do: false

  defp branch_puts({:->, _, [heads, body]}, scope, timed),
    do: puts(body, scope, timed or timed?(heads, scope))

  defp branch_puts({:cond, _, [[do: clauses]]}, scope, timed),
    do: Enum.flat_map(clauses, &branch_puts(&1, scope, timed))

  defp branch_puts({_, _, [condition | rest]}, scope, timed) do
    timed = timed or timed?(condition, scope)
    Enum.flat_map(rest, &puts(&1, scope, timed))
  end

  defp children({_, _, args}) when is_list(args), do: args
  defp children(list) when is_list(list), do: list
  defp children({left, right}), do: [left, right]
  defp children(_), do: []

  defp put?(node, scope), do: Code.calls?(node, scope.module, ":persistent_term", [:put])

  defp timed?(expr, scope) do
    expr
    |> Code.nodes()
    |> Enum.any?(fn
      {name, _, context} when is_atom(name) and is_atom(context) ->
        MapSet.member?(scope.vars, name) or Regex.match?(scope.names, to_string(name))

      node ->
        clock?(Code.call(node, scope.module), scope, 1)
    end)
  end

  # A clock read, directly or in one of the module's functions (`now()`).
  defp clock?(%{module: nil, fun: fun}, scope, 1) do
    for clause <- Code.clauses(scope.module, fun),
        node <- Code.nodes(clause.body),
        reduce: false do
      found -> found or clock?(Code.call(node, scope.module), scope, 0)
    end
  end

  defp clock?(%{module: module, fun: fun}, scope, _) when module != nil,
    do: Code.matches?(scope.calls, module, fun)

  defp clock?(_, _, _), do: false

  defp message,
    do:
      "`:persistent_term.put` refreshed on a time: each put of an existing key scans every process (a global GC). " <>
        "Keep expiring values in ETS owned by a supervised process."
end
