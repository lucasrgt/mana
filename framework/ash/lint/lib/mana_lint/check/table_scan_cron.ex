defmodule ManaLint.Check.TableScanCron do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [
      workers: ["Oban.Worker", "Oban.Pro.Worker"],
      time_calls: [
        ~r/^System\.(monotonic_time|os_time|system_time)$/,
        ~r/^(DateTime|NaiveDateTime|Date)\.(utc_now|utc_today|add|shift)$/
      ],
      time_names:
        ~r/^(now|today|cutoff|threshold|\w+_at|\w+_before|\w+_after|expires?(_\w+)?|deadline)$/
    ],
    explanations: [
      check: """
      Flags an Oban worker whose `perform/1` (or a function of its module it
      calls) reads records filtered by a timestamp against now — `now()`,
      `ago/2`, `from_now/2`, `^DateTime.add(now, ...)` in an
      `Ash.Query.filter` or an Ecto `where:` — and then iterates them.

      That is a deadline, a retention rule or a timed reconciliation written
      as a cron sweep. It scans the table on every run whether anything is
      due, acts up to a whole interval late, races the user acting on the
      same record (the sweep read it before they changed it), and every new
      timed rule needs another worker, schedule and test.

      Instead, declare it on the resource and let Mana schedule it per
      record, in the transaction that makes it due:

      - a `Mana.Entity` deadline (`deadline :expire, action: :expire, at:
        :expires_at, when: expr(status == :pending)`) — checked again when
        the job runs, so a record that moved on is left alone;
      - `Mana.Retention` for data kept for a period;
      - `Mana.Reconcile` with `within:` for state that must converge;
      - or an AshOban trigger (`scheduler_cron` with a `where` filter), which
        at least runs each record through an action.
      """,
      params: [
        workers: "Modules whose `use` marks an Oban worker.",
        time_calls: "Calls that read or shift the clock (forms as in `effects`).",
        time_names: "Variables whose name says they hold a time."
      ]
    ]

  alias ManaLint.Code

  @expr_clock [:now, :ago, :from_now, :today, :datetime_add, :date_add]

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    workers = Params.get(params, :workers, __MODULE__)

    scope = fn module ->
      %{
        module: module,
        calls: Params.get(params, :time_calls, __MODULE__),
        names: Params.get(params, :time_names, __MODULE__)
      }
    end

    for module <- source_file |> Code.ast() |> Code.modules(),
        Enum.any?(module.uses, &(&1 in workers)),
        bodies = reachable(module),
        filter <- timed_filters(bodies, scope.(module)),
        iterates?(bodies, module),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, filter, message())
  end

  defp reachable(module) do
    start = for clause <- Code.clauses(module, :perform), do: clause.body
    follow(module, start, MapSet.new([:perform]))
  end

  defp follow(module, bodies, seen) do
    names =
      for body <- bodies,
          node <- Code.nodes(body),
          name <- local(node, module),
          not MapSet.member?(seen, name),
          uniq: true,
          do: name

    case names do
      [] ->
        bodies

      names ->
        follow(
          module,
          bodies ++ Enum.flat_map(names, &bodies_of(module, &1)),
          MapSet.union(seen, MapSet.new(names))
        )
    end
  end

  defp bodies_of(module, name), do: for(clause <- Code.clauses(module, name), do: clause.body)

  defp local(node, module) do
    case {Code.local_capture(node), Code.call(node, module)} do
      {{name, _}, _} ->
        [name]

      {nil, %{module: nil, fun: name}} ->
        if Code.clauses(module, name) != [], do: [name], else: []

      _ ->
        []
    end
  end

  defp timed_filters(bodies, scope) do
    for body <- bodies,
        node <- Code.nodes(body),
        condition <- conditions(node, scope.module),
        timed?(condition, scope),
        do: node
  end

  defp conditions(node, module) do
    case Code.call(node, module) do
      %{module: "Ash.Query", fun: :filter, args: [_, condition | _]} ->
        [condition]

      %{module: nil, fun: :filter, args: [_, condition]} ->
        [condition]

      %{module: m, fun: :from, args: [_, options]} when m in [nil, "Ecto.Query"] ->
        List.wrap(Code.option(options, :where))

      %{module: m, fun: :where, args: [_, _, condition]} when m in [nil, "Ecto.Query"] ->
        [condition]

      _ ->
        []
    end
  end

  defp timed?(condition, scope) do
    condition
    |> Code.nodes()
    |> Enum.any?(fn
      {:^, _, [pinned]} ->
        clock?(pinned, scope)

      node ->
        match?(%{module: nil, fun: fun} when fun in @expr_clock, Code.call(node, scope.module))
    end)
  end

  defp clock?(expr, scope) do
    expr
    |> Code.nodes()
    |> Enum.any?(fn
      {name, _, context} when is_atom(name) and is_atom(context) ->
        Regex.match?(scope.names, to_string(name))

      node ->
        remote_clock?(Code.call(node, scope.module), scope)
    end)
  end

  defp remote_clock?(%{module: module, fun: fun}, scope) when module != nil,
    do: Code.matches?(scope.calls, module, fun)

  defp remote_clock?(_, _), do: false

  defp iterates?(bodies, module) do
    Enum.any?(bodies, fn body ->
      body
      |> Code.nodes()
      |> Enum.any?(fn
        {:for, _, _} ->
          true

        node ->
          match?(%{module: m} when m in ["Enum", "Stream"], Code.call(node, module)) or
            bulk?(node, module)
      end)
    end)
  end

  defp bulk?(node, module),
    do:
      Code.calls?(node, module, "Ash", [
        :bulk_update,
        :bulk_update!,
        :bulk_destroy,
        :bulk_destroy!
      ])

  defp message,
    do:
      "A worker that scans a timestamp against now and acts on each row: a deadline or retention written as a cron. " <>
        "Declare it on the resource (`Mana.Entity` deadline, `Mana.Retention`, `Mana.Reconcile within:`)."
end
