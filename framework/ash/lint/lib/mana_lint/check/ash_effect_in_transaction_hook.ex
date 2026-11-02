defmodule ManaLint.Check.AshEffectInTransactionHook do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    run_on_all: true,
    param_defaults: [
      effects: [
        ~r/(^|\.)Stripe(\.\w+)*\.(?!get_|list_|retrieve|config$|signed\?$)\w+[?!]?$/,
        "Mana.Storage.put",
        "Mana.Storage.delete",
        ~r/(^|\.)Mail(er)?\.deliver\w*!?$/,
        ~r/(^|\.)Push\.send!?$/,
        ~r/^Req\.(post|put|patch|delete|request|run)!?$/,
        ~r/^Finch\.(request|stream)!?$/,
        ":httpc.request",
        ~r/(^|\.)(PubSub|Endpoint)\.(local_)?broadcast(_from)?!?$/,
        "Mana.Entity.announce",
        ~r/^Mana\.Notifications\.notify!?$/,
        "Mana.Privacy.erase"
      ],
      after_transaction_effects: [
        ~r/(^|\.)(PubSub|Endpoint)\.(local_)?broadcast(_from)?!?$/,
        "Mana.Entity.announce",
        ~r/^Mana\.Notifications\.notify!?$/
      ],
      follow_calls: true
    ],
    explanations: [
      check: """
      Flags an external effect — a payment call, a storage write or delete, an
      email, a push, an HTTP request, a PubSub/Endpoint broadcast,
      `Mana.Entity.announce`, `Mana.Privacy.erase` — inside a function given to
      `Ash.Changeset.before_action/after_action/around_action` or to a
      transaction opened by hand (`Ash.transact`, `Repo.transaction`), in a
      change's `change/3` body, and a broadcast or notice inside
      `after_transaction`.

      `before_action`, `after_action` and `around_action` run inside the
      action's database transaction. The transaction can still roll back (a
      later hook fails, an outer action that called this one fails, a
      checkpoint's dry run), but money moved, a file deleted, an email sent or
      a broadcast heard stay done: the database says one thing, the world
      another. Holding the transaction open across an HTTP call also holds its
      row locks. `change/3` runs every time the changeset is built, before
      validation, and inside the caller's transaction when the action is
      nested. `after_transaction` runs after this action's own transaction,
      which, inside an outer action, is not the commit yet.

      Instead:

      - an effect the write depends on (charge before saving) goes in
        `Ash.Changeset.before_transaction`, with an idempotency key;
      - an effect that follows the write goes after the commit: an Ash
        notifier (which runs after the outermost commit), or an Oban job
        inserted in the action, atomic with it, whose worker performs the
        effect and retries;
      - a live update is a `Mana.Entity` announcement, a notice a declared
        `Mana.Notifications` notify — both already deliver after commit.

      `before_transaction`, `Oban.insert` and notifier modules are not flagged.
      Calls are followed into the project's own functions, so a hook calling
      `Billing.refund/1` that calls Stripe is flagged at the hook, with the
      path in the message.
      """,
      params: [
        effects:
          "Calls that are external effects: a module (all its functions), `\"Mod.fun\"`, `{Mod, :fun}` or a regex matched against `\"Mod.fun\"`. Add your adapters; add `\":telemetry.execute\"` to count telemetry as an effect.",
        after_transaction_effects:
          "The calls flagged inside `after_transaction` (broadcasts and notices), same forms.",
        follow_calls:
          "Follow calls into the project's own functions (all source files) to find effects they reach."
      ]
    ]

  alias ManaLint.Code

  @in_action [:before_action, :after_action, :around_action]

  @impl true
  def run_on_all_source_files(exec, source_files, params) do
    effects = Params.get(params, :effects, __MODULE__)
    notices = Params.get(params, :after_transaction_effects, __MODULE__)
    parsed = Enum.map(source_files, &{&1, &1 |> Code.ast() |> Code.modules()})
    graph = if Params.get(params, :follow_calls, __MODULE__), do: graph(parsed), else: %{}
    sets = %{action: {effects, reach(graph, effects)}, notice: {notices, reach(graph, notices)}}

    Enum.each(parsed, fn {source_file, modules} ->
      issue_meta = IssueMeta.for(source_file, params)

      modules
      |> Enum.flat_map(&module_issues(&1, sets, issue_meta))
      |> Enum.uniq_by(&{&1.line_no, &1.column})
      |> append_issues_and_timings(exec)
    end)

    :ok
  end

  defp module_issues(module, sets, issue_meta) do
    hooks =
      for node <- Code.module_nodes(module),
          {hook, functions} <- [Code.hook(node, module) || transaction(node, module)],
          set <- [hook_set(hook, sets)],
          set != nil,
          function <- functions,
          {call, chain} <- function_effects(function, module, set),
          do: Code.issue(__MODULE__, issue_meta, call, hook_message(hook, chain))

    hooks ++ change_issues(module, sets.action, issue_meta)
  end

  # A function run inside a transaction opened by hand.
  defp transaction(node, module) do
    with %{module: m, fun: fun, args: args} = call when m != nil <- Code.call(node, module),
         true <- transaction?(m, fun),
         [_ | _] = functions <- Enum.filter(args, &Code.function?/1) do
      {Code.name(call), functions}
    else
      _ -> nil
    end
  end

  defp transaction?("Ash", :transact), do: true
  defp transaction?("Ash.DataLayer", :transaction), do: true

  defp transaction?(module, fun),
    do: fun in [:transaction, :transact] and String.ends_with?(module, "Repo")

  defp hook_set(hook, sets) when hook in @in_action or is_binary(hook), do: sets.action
  defp hook_set(:after_transaction, sets), do: sets.notice
  defp hook_set(_, _), do: nil

  defp change_issues(module, set, issue_meta) do
    if "Ash.Resource.Change" in module.uses do
      for clause <- Code.clauses(module, :change),
          clause.arity == 3,
          {call, chain} <- effects_in(clause.body, module, set),
          do: Code.issue(__MODULE__, issue_meta, call, change_message(chain))
    else
      []
    end
  end

  defp function_effects(function, module, set) do
    case Code.local_capture(function) do
      {name, meta} -> capture_effect({name, meta, nil}, {module.name, name}, set)
      nil -> effects_in(function, module, set)
    end
  end

  defp capture_effect(node, {mod, fun} = target, {patterns, reached}) do
    cond do
      Code.matches?(patterns, mod, fun) -> [{node, [label(target)]}]
      chain = reached[target] -> [{node, [label(target) | chain]}]
      true -> []
    end
  end

  defp effects_in(ast, module, set) do
    for {node, target} <- calls(ast, module),
        effect <- capture_effect(node, target, set),
        do: effect
  end

  # Every call `ast` makes where it runs: the functions it hands to changeset
  # hooks run later, elsewhere.
  defp calls(ast, module) do
    ast
    |> Code.strip_hooks(module)
    |> Code.nodes(&match?({:defmodule, _, _}, &1))
    |> Enum.flat_map(&target(&1, module))
  end

  defp target(node, module) do
    case Code.local_capture(node) do
      {name, meta} ->
        [{{name, meta, nil}, {module.name, name}}]

      nil ->
        case Code.call(node, module) do
          %{module: nil, fun: fun} -> [{node, {module.name, fun}}]
          %{module: mod, fun: fun} -> [{node, {mod, fun}}]
          nil -> []
        end
    end
  end

  defp graph(parsed) do
    for {_, modules} <- parsed,
        module <- modules,
        clause <- Code.defs(module),
        reduce: %{} do
      graph ->
        calls = for {node, target} <- calls(clause.body, module), do: {target, node}
        Map.update(graph, {module.name, clause.name}, calls, &(&1 ++ calls))
    end
  end

  # The project functions that reach an effect, each with the path to it.
  defp reach(graph, patterns) do
    direct =
      for {key, calls} <- graph,
          {{mod, fun}, _} <- [
            Enum.find(calls, fn {{m, f}, _} -> Code.matches?(patterns, m, f) end)
          ],
          into: %{},
          do: {key, [label({mod, fun})]}

    propagate(graph, direct)
  end

  defp propagate(graph, known) do
    found =
      for {key, calls} <- graph,
          not Map.has_key?(known, key),
          {target, _} <- [Enum.find(calls, fn {target, _} -> Map.has_key?(known, target) end)],
          into: %{},
          do: {key, [label(target) | known[target]]}

    if found == %{}, do: known, else: propagate(graph, Map.merge(known, found))
  end

  defp label({mod, fun}),
    do: Code.name(%{module: mod |> String.split(".") |> List.last(), fun: fun})

  defp hook_message(:after_transaction, chain),
    do:
      "#{path(chain)} in `after_transaction`: inside an outer action the change is not committed yet " <>
        "and may roll back. Announce from an Ash notifier, which runs after the outermost commit."

  defp hook_message(transaction, chain) when is_binary(transaction),
    do:
      "#{path(chain)} inside `#{transaction}`, in its transaction: a rollback does not undo it. " <>
        "Run it before the transaction (with an idempotency key) or after the commit (an Oban job inserted in it)."

  defp hook_message(hook, chain),
    do:
      "#{path(chain)} inside `#{hook}`, in the action's transaction: a rollback does not undo it. " <>
        "Move it to `before_transaction` (with an idempotency key) or after the commit " <>
        "(an Ash notifier, or an Oban job inserted in the action)."

  defp change_message(chain),
    do:
      "#{path(chain)} in `change/3`, which runs whenever the changeset is built: before validation " <>
        "and inside a caller's transaction. Move it to `before_transaction` or after the commit."

  defp path([name]), do: "`#{name}` is an external effect"
  defp path([name | rest]), do: "`#{name}` reaches an external effect (#{Enum.join(rest, " → ")})"
end
