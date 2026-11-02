defmodule ManaLint.Check.ImperativeNotice do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      notices: [~r/(^|\.)Notifications\.notify!?$/],
      senders: ["Mana.Notifications.Sender"],
      primitives: [~r/^Mana\.Notifications(\.|$)/]
    ],
    explanations: [
      check: """
      Flags a notice sent by hand: a call to the app's `Notifications.notify`
      (or `notify!`) from anywhere but the module that delivers declared
      notices.

      A notice sent from an action's code is easy to send before the commit,
      or for a change that rolled back, to send twice on a retry, and to
      forget in the next action that should send it; the client cannot route
      or group it, since nothing declares it.

      Instead, declare it next to the action that causes it:

          notifications do
            sender MyApp.Notifications.Sender
            notify :accept, to: :traveler_id, template: "booking.accepted", category: :bookings
          end

      `Mana.Notifications` sends it once the change commits (through an Oban
      job inserted with it, when the app runs Oban), never for one rolled
      back, and the contract carries it to clients.

      The sender itself — a module with `@behaviour
      Mana.Notifications.Sender` — is where notices are delivered by hand,
      and is left alone.
      """,
      params: [
        notices: "The calls that send a notice (forms as in `effects`).",
        senders: "Behaviours whose modules deliver notices.",
        primitives: "Modules (regexes or substrings) of Mana's own notifications."
      ]
    ]

  alias ManaLint.Code

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    notices = Params.get(params, :notices, __MODULE__)
    senders = Params.get(params, :senders, __MODULE__)
    primitives = Params.get(params, :primitives, __MODULE__)

    for module <- source_file |> Code.ast() |> Code.modules(),
        not Code.listed?(primitives, module.name),
        not sender?(module, senders),
        node <- Code.module_calls(module),
        %{module: target} = call when is_binary(target) <- [Code.call(node, module)],
        Code.matches?(notices, target, call.fun),
        do: Code.issue(__MODULE__, issue_meta, node, message(call))
  end

  defp sender?(module, senders) do
    module
    |> Code.module_nodes()
    |> Enum.any?(fn
      {:@, _, [{:behaviour, _, [behaviour]}]} -> Code.resolve(behaviour, module) in senders
      _ -> false
    end)
  end

  defp message(call),
    do:
      "`#{Code.name(call)}` sends a notice by hand. " <>
        "Declare it in the resource's `notifications` (Mana.Notifications): it goes out after the commit."
end
