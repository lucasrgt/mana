defmodule Mana.Explore do
  @moduledoc """
  Tries to break an app's laws. Each run starts from a situation and takes
  random steps: something a person may do now (a verb a record offers an
  actor: `when` and policies already hold) or something the world does (a
  `Mana.Entity` deadline that holds comes due, or an app event: a webhook
  arrives). After every step each
  `Mana.Invariants` law is asked of every record; at the end of a run the
  world settles (`:settle`) and the `Mana.Reconcile` rules named in
  `:eventual` must have converged. A breach is shrunk to the shortest
  sequence of steps that still breaks the same law.

      Mana.Explore.run(
        resources: [Booking, Charge, Service],
        setup: fn -> %{actors: [host, traveler]} end,
        isolate: fn run -> Repo.transaction(fn -> Repo.rollback(run.()) end) |> elem(1) end,
        input: fn Booking, :counter, _record, _actor, _world -> %{slot: tomorrow()}; _, _, _, _, _ -> %{} end,
        events: [{:stripe_pays, fn _world -> pending_charges() end, fn charge, _world -> pay(charge) end}],
        settle: fn world -> deliver_webhooks(world) end,
        eventual: [{Booking, :cancelled_releases_money}],
        runs: 50, steps: 25, seed: 1
      )

  `:read` (resource, world) narrows the records explored and judged to the
  run's own, when the database holds others.

  The answer lists the breaches with their shrunk steps, and `coverage`:
  how often each move was offered, done and refused. A move never done
  proves nothing about the laws it could break — give it input, or a
  situation that reaches it. Record-less collection verbs (an account's own
  verbs) are not moves yet.
  """

  @default [runs: 30, steps: 20, seed: 1, input: nil, read: nil, events: [], deadlines: true, settle: nil, eventual: [], shrink: 150]

  def run(opts) do
    opts = Keyword.merge(@default, opts)
    opts = Keyword.put_new_lazy(opts, :laws, fn -> Enum.filter(opts[:resources], &(Mana.Invariants in Spark.extensions(&1))) end)

    {breaches, coverage} =
      Enum.reduce(1..opts[:runs], {[], %{}}, fn n, {breaches, coverage} ->
        rng = :rand.seed_s(:exsss, {opts[:seed], n, 7})
        %{breach: breach, coverage: coverage} = isolated(opts, fn -> walk(opts, rng, coverage) end)
        {if(breach, do: [Map.put(breach, :run, n) | breaches], else: breaches), coverage}
      end)

    breaches =
      breaches
      |> Enum.reverse()
      |> Enum.uniq_by(& &1.law)
      |> Enum.map(&shrunk(opts, &1))

    %{runs: opts[:runs], breaches: breaches, coverage: coverage}
  end

  @doc "The moves never done in a run's answer: what the exploration could not reach."
  def unreached(%{coverage: coverage}), do: for({move, %{done: 0}} <- coverage, do: move) |> Enum.sort()

  @doc "A breach as lines a person reads."
  def describe(%{law: law, detail: detail, steps: steps}) do
    ["breaks #{format_law(law)}: #{detail}" | Enum.with_index(steps, 1) |> Enum.map(fn {step, i} -> "  #{i}. #{format_step(step)}" end)]
    |> Enum.join("\n")
  end

  defp format_law({:invariant, resource, name}), do: "#{inspect(resource)} invariant #{name}"
  defp format_law({:eventual, resource, name}), do: "#{inspect(resource)} rule #{name} (after settling)"
  defp format_law({:crash, move}), do: "#{move} (crashed)"

  defp format_step(%{move: move, actor: nil, target: target}), do: "#{move} #{format_target(target)}"
  defp format_step(%{move: move, actor: actor, target: target}), do: "actor #{actor} does #{move} #{format_target(target)}"
  defp format_target({resource, n}), do: "on #{resource |> Module.split() |> List.last()} ##{n}"
  defp format_target(nil), do: ""

  # One run: random steps until a law breaks, nothing is possible or the
  # budget is spent; the trace names records by the order they appeared, so
  # a replay from the same situation finds them again.
  defp walk(opts, rng, coverage) do
    world = opts[:setup].()
    state = %{world: world, rng: rng, handles: %{}, seen: %{}, trace: [], coverage: coverage}
    state = discover(state, opts)

    # Eventual rules are asked only where a run ends, so runs end anywhere.
    {length, rng} = :rand.uniform_s(opts[:steps], state.rng)
    state = %{state | rng: rng}

    Enum.reduce_while(1..length, state, fn _, state ->
      case moves(state, opts) do
        [] ->
          {:halt, state}

        moves ->
          state = count(state, moves, :offered)
          {move, rng} = pick(moves, state.rng)
          state = %{state | rng: rng}

          case perform(move, state, opts) do
            {:crash, error, state} -> {:halt, Map.put(state, :breach, %{law: {:crash, move.name}, detail: error})}
            {outcome, state} -> continue(count(state, [move], outcome), opts)
          end
      end
    end)
    |> finish(opts)
  end

  # The kind of move first, then which record: a rare move (a webhook while
  # a checkout is open) is as likely as a common one (asking for a booking).
  defp pick(moves, rng) do
    kinds = moves |> Enum.group_by(& &1.name) |> Enum.sort_by(&elem(&1, 0))
    {kind, rng} = :rand.uniform_s(length(kinds), rng)
    {_, instances} = Enum.at(kinds, kind - 1)
    {instance, rng} = :rand.uniform_s(length(instances), rng)
    {Enum.at(instances, instance - 1), rng}
  end

  defp continue(state, opts) do
    state = discover(state, opts)

    case broken(state, opts) do
      nil -> {:cont, state}
      breach -> {:halt, Map.put(state, :breach, breach)}
    end
  end

  defp finish(%{breach: _} = state, _opts), do: %{breach: Map.put(state.breach, :steps, Enum.reverse(state.trace)), coverage: state.coverage}

  defp finish(state, opts) do
    if opts[:settle], do: opts[:settle].(state.world)

    breach =
      Enum.find_value(opts[:eventual], fn {resource, rule} ->
        case Mana.Reconcile.diverging(resource, rule, read(opts, resource, state.world)) do
          [] -> nil
          diverging -> %{law: {:eventual, resource, rule}, detail: Enum.map_join(diverging, "; ", &"#{handle_name(state, resource, &1.id)}: #{&1.detail}")}
        end
      end)

    %{breach: breach && Map.put(breach, :steps, Enum.reverse(state.trace)), coverage: state.coverage}
  end

  defp broken(state, opts) do
    Enum.find_value(opts[:laws], fn resource ->
      Enum.find_value(read(opts, resource, state.world), fn record ->
        case Mana.Invariants.broken(record) do
          [] -> nil
          [{law, detail} | _] -> %{law: {:invariant, resource, law.name}, detail: "#{handle_name(state, resource, record.id)}: #{detail}"}
        end
      end)
    end)
  end

  defp handle_name(state, resource, id) do
    case state.handles[{resource, id}] do
      {_, n} -> "#{resource |> Module.split() |> List.last()} ##{n}"
      nil -> id
    end
  end

  # Records get handles in the order they appear; several appearing in one
  # step are ordered by id, which a replay may order differently (rare).
  defp discover(state, opts) do
    Enum.reduce(opts[:resources], state, fn resource, state ->
      opts
      |> read(resource, state.world)
      |> Enum.reject(&Map.has_key?(state.handles, {resource, &1.id}))
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce(state, fn record, state ->
        n = Map.get(state.seen, resource, 0) + 1
        %{state | handles: Map.put(state.handles, {resource, record.id}, {resource, n}), seen: Map.put(state.seen, resource, n)}
      end)
    end)
  end

  defp moves(state, opts) do
    actors = state.world.actors

    explored = MapSet.new(opts[:resources], &Mana.Entity.type/1)

    verbs =
      for resource <- opts[:resources],
          record <- read(opts, resource, state.world),
          {actor, a} <- Enum.with_index(actors),
          offered <- Mana.Verbs.offered(record, actor),
          explored?(offered, explored),
          do: %{name: move_name(resource, offered), verb: offered, record: record, actor: a, target: state.handles[{resource, record.id}]}

    events =
      for {name, targets, _} <- opts[:events],
          target <- targets.(state.world),
          do: %{name: to_string(name), event: name, record: target, actor: nil, target: state.handles[{target.__struct__, target.id}]}

    deadlines =
      if opts[:deadlines] do
        for resource <- opts[:resources],
            Mana.Entity in Spark.extensions(resource),
            record <- read(opts, resource, state.world),
            deadline <- Mana.Entity.observe(record)["deadlines"],
            do: %{name: "#{Mana.Entity.type(resource)}.deadline.#{deadline}", deadline: deadline, record: record, actor: nil, target: state.handles[{resource, record.id}]}
      else
        []
      end

    verbs ++ events ++ deadlines
  end

  # A record also offers its children's verbs ("chat.open"); those of a
  # resource left out of the exploration are not moves.
  defp explored?(offered, explored) do
    case String.split(offered, ".") do
      [type, _] -> MapSet.member?(explored, type)
      _ -> true
    end
  end

  defp move_name(resource, offered) do
    if String.contains?(offered, "."), do: offered, else: "#{Mana.Entity.type(resource)}.#{offered}"
  end

  defp count(state, moves, key) do
    coverage =
      Enum.reduce(moves |> Enum.map(& &1.name) |> Enum.uniq(), state.coverage, fn name, coverage ->
        Map.update(coverage, name, Map.put(%{offered: 0, done: 0, refused: 0}, key, 1), &Map.update!(&1, key, fn n -> n + 1 end))
      end)

    %{state | coverage: coverage}
  end

  defp perform(move, state, opts) do
    step = %{move: move.name, actor: move.actor, target: move.target}
    state = %{state | trace: [step | state.trace]}

    outcome =
      try do
        cond do
          Map.has_key?(move, :event) -> event(move, state, opts)
          Map.has_key?(move, :deadline) -> Mana.Entity.fake(move.record.__struct__, move.record.id, move.deadline)
          true -> verb(move, state, opts)
        end
      rescue
        error -> {:crash, Exception.format(:error, error, __STACKTRACE__) |> String.slice(0, 2000)}
      end

    case outcome do
      {:crash, error} -> {:crash, error, state}
      {:ok, _} -> {:done, state}
      :ok -> {:done, state}
      _ -> {:refused, state}
    end
  end

  defp event(move, state, opts) do
    {_, _, run} = Enum.find(opts[:events], &(elem(&1, 0) == move.event))
    run.(move.record, state.world)
  end

  defp verb(move, state, opts) do
    actor = Enum.at(state.world.actors, move.actor)
    record = move.record

    {resource, name, input} =
      case String.split(move.verb, ".") do
        [type, name] ->
          child = Enum.find(opts[:resources], &(Mana.Entity.type(&1) == type))
          verb = Enum.find(Mana.Verbs.declared(child), &(to_string(&1.name) == name))
          {_parent, field} = verb.from
          {child, verb, Map.put(input(opts, child, verb.name, record, actor, state), field, record.id)}

        [name] ->
          verb = Enum.find(Mana.Verbs.declared(record.__struct__), &(to_string(&1.name) == name))
          {record.__struct__, verb, input(opts, record.__struct__, verb.name, record, actor, state)}
      end

    if input == :skip do
      :skip
    else
      action = Mana.Verbs.action(name)

      case Ash.Resource.Info.action(resource, action).type do
        :update -> Ash.update(record, input, action: action, actor: actor)
        :destroy -> Ash.destroy(record, action: action, actor: actor)
        :create -> Ash.create(resource, input, action: action, actor: actor)
        :action -> resource |> Ash.ActionInput.for_action(action, input, actor: actor) |> Ash.run_action()
      end
    end
  end

  defp read(opts, resource, world) do
    case opts[:read] do
      nil -> Ash.read!(resource, authorize?: false)
      fun -> fun.(resource, world)
    end
  end

  defp input(opts, resource, verb, record, actor, state) do
    case opts[:input] do
      nil -> %{}
      fun -> fun.(resource, verb, record, actor, state.world)
    end
  end

  defp isolated(opts, run) do
    case opts[:isolate] do
      nil -> run.()
      isolate -> isolate.(run)
    end
  end

  # Delta debugging over the trace: drop chunks, then single steps, keeping
  # a smaller trace whenever its replay still breaks the same law.
  defp shrunk(opts, breach) do
    {steps, _} =
      Enum.reduce_while(Stream.cycle([:pass]), {breach.steps, opts[:shrink]}, fn _, {steps, budget} ->
        case smaller(opts, breach.law, steps, budget) do
          {:smaller, steps, budget} -> {:cont, {steps, budget}}
          {:done, budget} -> {:halt, {steps, budget}}
        end
      end)

    replayed = replay(opts, steps)
    %{breach | steps: steps} |> Map.put(:detail, (replayed && replayed.detail) || breach.detail) |> Map.put(:original_length, length(breach.steps))
  end

  defp smaller(_opts, _law, _steps, budget) when budget <= 0, do: {:done, budget}

  defp smaller(opts, law, steps, budget) do
    candidates =
      for size <- chunk_sizes(length(steps)), start <- 0..(length(steps) - size)//size, size < length(steps), do: Enum.take(steps, start) ++ Enum.drop(steps, start + size)

    Enum.reduce_while(candidates, {:done, budget}, fn candidate, {:done, budget} ->
      if budget <= 0 do
        {:halt, {:done, 0}}
      else
        case replay(opts, candidate) do
          %{law: ^law} -> {:halt, {:smaller, candidate, budget - 1}}
          _ -> {:cont, {:done, budget - 1}}
        end
      end
    end)
  end

  defp chunk_sizes(n), do: Stream.iterate(max(div(n, 2), 1), &div(&1, 2)) |> Enum.take_while(&(&1 >= 1))

  defp replay(opts, steps) do
    isolated(opts, fn ->
      state = discover(%{world: opts[:setup].(), rng: nil, handles: %{}, seen: %{}, trace: [], coverage: %{}}, opts)

      Enum.reduce_while(steps, state, fn step, state ->
        case Enum.find(moves(state, opts), &(&1.name == step.move and &1.actor == step.actor and &1.target == step.target)) do
          nil ->
            {:cont, state}

          move ->
            case perform(move, state, opts) do
              {:crash, error, state} -> {:halt, Map.put(state, :breach, %{law: {:crash, move.name}, detail: error})}
              {_, state} -> continue(state, opts)
            end
        end
      end)
      |> finish(opts)
      |> Map.get(:breach)
    end)
  end
end
