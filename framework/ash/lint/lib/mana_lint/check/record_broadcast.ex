defmodule ManaLint.Check.RecordBroadcast do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      broadcasts: [~r/(^|\.)(PubSub|Endpoint)\.(local_)?broadcast(_from)?!?$/],
      writes: [~r/^Ash\.(create|update|destroy|bulk_create|bulk_update|bulk_destroy)!?$/],
      record_modules: [
        "Ash.Resource",
        "Ash.Resource.Change",
        "Ash.Notifier",
        "Ash.Resource.ManualCreate",
        "Ash.Resource.ManualUpdate",
        "Ash.Resource.ManualDestroy"
      ]
    ],
    explanations: [
      check: """
      Flags a PubSub or Endpoint broadcast of a record's change written by
      hand: one in a resource, a change, a notifier or a manual action, or in
      a function that also writes through Ash (`Ash.create/update/destroy`,
      their bulk forms).

      Each such broadcast invents its own topic and payload, so every client
      subscribes its own way; it is easy to send before the commit (or for a
      change that rolled back) and to forget on the next action that changes
      the record.

      Instead, declare the record an entity and let it announce itself:

          entity do
            broadcast MyAppWeb.Endpoint
            audience [:host_id, :traveler_id]
          end

      `Mana.Entity` announces `changed` on `entity:<type>:<id>` after the
      outermost commit of every create, update and destroy, never for one
      rolled back, and clients refresh the record from it.

      Broadcasts that are not about a record's change (presence, typing, a
      channel's own messages) are left alone, and so is the module the
      entity broadcasts through: one that defines `broadcast/3` is the
      broadcaster `entity do broadcast ... end` names.
      """,
      params: [
        broadcasts: "The broadcast calls (forms as in `effects`).",
        writes: "Calls that write a record through Ash.",
        record_modules:
          "Modules whose `use` marks code about a record's change (a resource, a change, a notifier)."
      ]
    ]

  alias ManaLint.Code

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    broadcasts = Params.get(params, :broadcasts, __MODULE__)
    writes = Params.get(params, :writes, __MODULE__)
    record_modules = Params.get(params, :record_modules, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        not broadcaster?(module),
        {_kind, nodes} = scope <- scopes(module, record_modules),
        writes?(scope, module, writes),
        node <- nodes,
        %{} = call <- [Code.call(node, module)],
        Code.matches?(broadcasts, call.module, call.fun),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, node, message(call))
  end

  defp broadcaster?(module),
    do: Enum.any?(Code.defs(module), &(&1.name == :broadcast and &1.arity == 3))

  # The code a broadcast is judged in: the whole module when it is about a
  # record's change, each function otherwise.
  defp scopes(module, record_modules) do
    if Enum.any?(module.uses, &(&1 in record_modules)),
      do: [{:record, Code.module_nodes(module)}],
      else: for(clause <- Code.defs(module), do: {:function, Code.nodes(clause.body)})
  end

  defp writes?({:record, _nodes}, _module, _writes), do: true

  defp writes?({:function, nodes}, module, writes) do
    Enum.any?(nodes, fn node ->
      case Code.call(node, module) do
        %{module: m, fun: fun} when not is_nil(m) -> Code.matches?(writes, m, fun)
        _ -> false
      end
    end)
  end

  defp message(call),
    do:
      "`#{Code.name(call)}` announces a record's change by hand. " <>
        "Declare the record a Mana.Entity (`entity do broadcast ... end`): it announces after the commit."
end
