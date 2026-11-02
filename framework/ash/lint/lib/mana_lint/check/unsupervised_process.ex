defmodule ManaLint.Check.UnsupervisedProcess do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      allowed_paths: [~r"(^|/)test/"],
      sleep_allowed_modules: [~r/Intervene/, ~r/(^|\.)Fake(\.|$)/, ~r/(^|\.)Moments(\.|$)/]
    ],
    explanations: [
      check: """
      Flags processes and timing written by hand:

      - `spawn/1,3`, `spawn_link`, `spawn_monitor`, `Process.spawn`,
        `:erlang.spawn*` and `Task.start/1,3` — a process no supervisor owns;
      - `Process.register/2` guarded by `rescue` or `catch` — a registered
        name used as a lock;
      - `Process.sleep/1` and `:timer.sleep/1` outside interventions, fakes and
        Moments — waiting by time.

      A process outside the supervision tree is not restarted when it dies,
      not stopped on shutdown (it can outlive the code that needed it or be
      killed mid-write), and invisible to observer tools. A name registered
      as a lock is released only when its owner dies, and the rescue that
      catches the race hides every other error. A sleep turns a missing
      signal into a timing assumption that holds on a laptop and fails under
      load.

      Instead:

      - start long-lived state as a child of the application's supervisor (a
        `GenServer` owning its ETS table, created in `init/1`); fire-and-forget
        work goes to `Task.Supervisor.start_child/2` or an Oban job;
      - make contention atomic where it happens: `:ets.insert_new/2`,
        `:ets.update_counter/4`, a database constraint or lock;
      - wait for the event itself: a message, `Process.monitor/1`, a
        `receive ... after`, a PubSub subscription.
      """,
      params: [
        allowed_paths: "Paths (regexes or substrings) where these are fine (tests).",
        sleep_allowed_modules:
          "Modules (regexes or substrings of the name) that may sleep: interventions and fakes."
      ]
    ]

  alias ManaLint.Code

  @spawns ~w(spawn spawn_link spawn_monitor)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Code.listed?(Params.get(params, :allowed_paths, __MODULE__), source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      sleepers = Params.get(params, :sleep_allowed_modules, __MODULE__)

      for module <- source_file |> Code.ast() |> Code.modules(),
          {node, message} <- spawns(module) ++ locks(module) ++ sleeps(module, sleepers) do
        Code.issue(__MODULE__, issue_meta, node, message)
      end
    end
  end

  defp spawns(module) do
    for node <- Code.module_nodes(module),
        %{} = call <- [Code.call(node, module)],
        spawn?(call),
        call.module != nil or Code.clauses(module, call.fun) == [],
        do: {node, "`#{Code.name(call)}` starts a process no supervisor owns. " <> supervised()}
  end

  defp spawn?(%{module: nil, fun: fun, args: [_ | _]}), do: fun in @spawns

  defp spawn?(%{module: m, fun: fun}) when m in ["Kernel", "Process", ":erlang"],
    do: fun in @spawns or fun == :spawn_opt

  defp spawn?(%{module: "Task", fun: :start}), do: true
  defp spawn?(_), do: false

  defp supervised,
    do:
      "Start it under a supervisor (`Task.Supervisor.start_child`, a child spec) or as an Oban job."

  defp locks(module) do
    for node <- Code.module_nodes(module),
        guarded <- guarded(node),
        inner <- Code.nodes(guarded),
        Code.calls?(inner, module, "Process", [:register]),
        do:
          {inner,
           "`Process.register` guarded by a rescue: a registered name used as a lock. " <>
             "Make the contended step atomic (`:ets.insert_new`, a constraint) in a supervised owner."}
  end

  # The code a `rescue` or `catch` guards (of a `try` or a function body).
  defp guarded(node) when is_list(node) do
    if Keyword.keyword?(node) and
         (Keyword.has_key?(node, :rescue) or Keyword.has_key?(node, :catch)),
       do: Keyword.get_values(node, :do),
       else: []
  end

  defp guarded(_), do: []

  defp sleeps(module, allowed) do
    if Code.listed?(allowed, module.name) do
      []
    else
      for node <- Code.module_nodes(module),
          Code.calls?(node, module, "Process", [:sleep]) or
            Code.calls?(node, module, ":timer", [:sleep]),
          do:
            {node,
             "`#{Code.name(Code.call(node, module))}` waits by time. " <>
               "Wait for the event itself (a message, a monitor, `receive ... after`)."}
    end
  end
end
