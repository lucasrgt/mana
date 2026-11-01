defmodule Mana.Explore do
  @moduledoc """
  The app searches its own state space, guided by what it already declares.

      report = Mana.Explore.run([MyApp.Bookings], setup: &MyApp.Explore.actors/0, runs: 200, depth: 12, seed: 1)

  A run starts from an empty store (`reset`), calls `setup` (which creates
  the people it needs and answers them by name, `%{host: host, traveler:
  traveler}`), then makes up to `depth` moves. A move is one of:

  - an actor performs a verb its record offers it now (`Mana.Verbs.offered/2`),
  - an actor starts a collection verb (`Mana.Verbs.available/2`, or a child
    verb its parent offers as `"type.verb"`),
  - the clock moves (`clock:`, by default the deadlines' and timed rules'
    durations): every `Mana.Entity` deadline that would be due runs,
  - a probe: an actor tries a verb its record does *not* offer, which the
    server must refuse.

  Inputs come from `Ash.Generator.action_input/3` (`generators:` overrides
  them per `{Resource, action}`); a field that points at another record
  (a `belongs_to` source) gets one that exists. After every move it checks
  what the declarations promise:

  | property | from | broken when |
  |---|---|---|
  | `:offer_honest` | verbs | an offered verb is refused by policy or by its own `when`, or crashes |
  | `:refusal_enforced` | verbs | a verb not offered is accepted |
  | `:idempotent` | `idempotent: true` | twice does not equal once |
  | `:inverse_restores` | `inverse:` | the inverse does not restore what the verb changed |
  | `:invariant` | `reconcile` | a rule diverges in a reached state |
  | `:eventually` | `reconcile` with `within:` | a record stays in scope past `within` on the moved clock |
  | `:flow_monotonic` | `flow` | the cursor moved back |
  | `:flow_deadlock` | `flow` | no one is offered the verb of a record's current step, and no deadline holds for it |
  | `:history_replays` | `history` | replaying a record's log does not rebuild it |

  A violation is shrunk to the shortest sequence of moves that still breaks
  the same property and kept in the report with that trace; `save/2`
  writes it where `replay_file/3` (a Moment's backend recipe) can rebuild
  it. Verbs that are `external:` or move money are never performed unless
  `external: :run`. A run is deterministic for a `seed`.

  The report also carries coverage (verbs declared, reached, never reached)
  and the affordance graph: for each record *shape* — its atom, boolean and
  enum fields — the verbs each actor was offered there, and the transitions
  between shapes. `Mana.Explore.Lock` writes it as `affordances.json`.

  Stores: ETS resources are emptied between runs; any other data layer needs
  `reset:` (a function), e.g. a fresh `Mana.Snapshot` scope per run.
  """
  require Ash.Query

  @properties [:offer_honest, :refusal_enforced, :idempotent, :inverse_restores, :invariant, :eventually, :flow_monotonic, :flow_deadlock, :history_replays]
  @timestamps [:inserted_at, :updated_at, :created_at]

  defmodule Violation do
    @moduledoc false
    @derive {Inspect, except: [:trace]}
    defstruct [:property, :resource, :verb, :actor, :detail, trace: [], shrunk_from: nil, run: nil]
  end

  defmodule Report do
    @moduledoc false
    defstruct seed: nil, runs: 0, moves: 0, violations: [], coverage: %{}, affordances: %{}, transitions: [], inconclusive: %{}, skipped: %{}
  end

  @doc "The properties `run/2` checks."
  def properties, do: @properties

  @doc """
  Explores `domains`. Options: `setup` (0-arity, answers `%{name => actor}`),
  `actors` (the same map, when no setup is needed), `resources` (the ones
  explored; every resource with verbs by default), `runs` (50), `depth`
  (10), `seed`, `clock` (`[{15, :minute}, ...]`), `properties`
  (subset of `properties/0`), `skip_rules` (reconcile rule names not
  checked, e.g. ones that call outside systems), `generators`, `external`
  (`:skip`), `reset`, `shrink` (true).
  """
  def run(domains, opts \\ []) do
    ctx = context(domains, opts)

    with_quiet_deadlines(fn ->
      {report, _} =
        Enum.reduce(1..ctx.runs, {%Report{seed: ctx.seed}, MapSet.new()}, fn index, {report, seen} ->
          {state, run_report} = run_once(ctx, ctx.seed + index)
          report = merge(report, run_report, state)

          {violations, seen} =
            for violation <- state.violations, reduce: {report.violations, seen} do
              {acc, seen} ->
                key = {violation.property, violation.resource, violation.verb}

                if MapSet.member?(seen, key),
                  do: {acc, seen},
                  else: {acc ++ [%{shrink(ctx, violation) | run: index}], MapSet.put(seen, key)}
            end

          {%{report | violations: violations}, seen}
        end)

      ctx.reset.(:done)
      %{report | runs: ctx.runs, coverage: coverage(ctx, report)}
    end)
  end

  @doc """
  A `reset:` for apps on Postgres: every run gets a fresh `Mana.Snapshot`
  scope cloned from `from` (the migrated base, or a named snapshot; `opts`
  go to `Mana.Snapshot.open/3`), the
  previous one is dropped, and this process uses it. Set `config :ash,
  disable_async?: true` where you explore, so no load escapes the scope.
  """
  def snapshot_reset(repo, from \\ :base, opts \\ []) do
    fn run ->
      if id = Process.delete({__MODULE__, :scope}) do
        repo.put_dynamic_repo(repo)
        Mana.Snapshot.drop(repo, id)
      end

      unless run == :done do
        id = Mana.Snapshot.open(repo, from, opts)
        Process.put({__MODULE__, :scope}, id)
        Mana.Snapshot.use_scope(repo, id)
      end

      :ok
    end
  end

  @doc "Performs `moves` (a violation's trace) from a fresh store; answers the first violation, or nil."
  def replay(domains, moves, opts \\ []) do
    ctx = context(domains, opts)
    with_quiet_deadlines(fn ->
      found = ctx |> replay_moves(moves, ctx.seed) |> elem(0) |> Map.get(:violations) |> List.first()
      ctx.reset.(:done)
      found
    end)
  end

  # ---------------------------------------------------------------------------
  # Setup

  defp context(domains, opts) do
    domains = List.wrap(domains)
    all = for domain <- domains, resource <- Ash.Domain.Info.resources(domain), uniq: true, do: resource
    explored = opts[:resources] || Enum.filter(all, &(Mana.Verbs in Spark.extensions(&1)))
    properties = MapSet.new(opts[:properties] || @properties)

    %{
      domains: domains,
      all: all,
      resources: explored,
      runs: opts[:runs] || 50,
      depth: opts[:depth] || 10,
      seed: opts[:seed] || :erlang.phash2(make_ref()),
      clock: opts[:clock] || default_clock(explored),
      properties: properties,
      skip_rules: MapSet.new(opts[:skip_rules] || []),
      generators: opts[:generators] || %{},
      external: opts[:external] || :skip,
      reset: opts[:reset] || (&default_reset(all, &1)),
      setup: opts[:setup] || fn -> opts[:actors] || %{anyone: nil} end,
      shrink: Keyword.get(opts, :shrink, true),
      probe: Keyword.get(opts, :probe, 0.25)
    }
  end

  defp default_clock(resources) do
    deadlines =
      for resource <- resources, Mana.Entity in Spark.extensions(resource), deadline <- Mana.Entity.deadlines(resource), match?({n, _} when is_integer(n), deadline.after),
          do: deadline.after

    timed = for resource <- resources, Mana.Reconcile in Spark.extensions(resource), rule <- Mana.Reconcile.declared(resource), match?({n, _} when is_integer(n), rule.within), do: rule.within
    # Windows read from a setting ({Module, :fun}) are not known here: give
    # those apps clock: explicitly.
    (deadlines ++ timed) |> Enum.uniq() |> Enum.map(fn {n, unit} -> {n + 1, unit} end)
  end

  defp default_reset(_resources, :done), do: :ok

  defp default_reset(resources, _run) do
    for resource <- resources do
      if Ash.DataLayer.data_layer(resource) == Ash.DataLayer.Ets do
        empty_ets(resource)
      else
        raise ArgumentError, "#{inspect(resource)} is not on ETS; give Mana.Explore a reset: function (e.g. a fresh Mana.Snapshot scope)"
      end
    end

    :ok
  end

  @doc """
  Empties an ETS resource and waits until its table is gone: `Ash.DataLayer.Ets.stop/1`
  only signals the table's owner, and a create right after it can still
  reach the table being deleted.
  """
  def empty_ets(resource) do
    owner = Process.whereis(Module.concat(Ash.DataLayer.Ets.Info.table(resource), Ash.DataLayer.Ets.TableManager))
    ref = owner && Process.monitor(owner)
    Ash.DataLayer.Ets.stop(resource)

    if ref do
      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  # Deadlines would be scheduled as Oban jobs; exploration runs them itself
  # when it moves the clock.
  defp with_quiet_deadlines(fun) do
    previous = Application.get_env(:mana_core, :deadline_inserter)
    Application.put_env(:mana_core, :deadline_inserter, fn _ -> :ok end)

    try do
      fun.()
    after
      if previous, do: Application.put_env(:mana_core, :deadline_inserter, previous), else: Application.delete_env(:mana_core, :deadline_inserter)
    end
  end

  # ---------------------------------------------------------------------------
  # Runs

  defp new_state(ctx, seed) do
    ctx.reset.(seed)
    actors = ctx.setup.()

    %{
      rand: :rand.seed_s(:exsss, {seed, seed * 7 + 1, seed * 13 + 3}),
      actors: actors,
      offset: 0,
      refs: %{},
      trace: [],
      violations: [],
      moves: 0,
      observed: %{},
      transitions: MapSet.new(),
      reached: %{},
      inconclusive: %{},
      skipped: %{},
      replaying: false,
      stamps: %{}
    }
    |> discover(ctx)
  end

  defp run_once(ctx, seed) do
    state = new_state(ctx, seed)

    state =
      Enum.reduce_while(1..ctx.depth, state, fn _, state ->
        state = observe_affordances(ctx, state)

        case choose(ctx, state) do
          {nil, state} ->
            {:halt, state}

          {move, state} ->
            state = perform_and_check(ctx, state, move)
            if state.violations == [], do: {:cont, state}, else: {:halt, state}
        end
      end)

    state = if state.violations == [], do: check_history(ctx, state), else: state
    {state, nil}
  end

  defp replay_moves(ctx, moves, seed) do
    state = %{new_state(ctx, seed) | replaying: true}

    state =
      Enum.reduce_while(moves, state, fn move, state ->
        state = perform_and_check(ctx, state, move)
        if state.violations == [], do: {:cont, state}, else: {:halt, state}
      end)

    state = if state.violations == [], do: check_history(ctx, state), else: state
    {state, nil}
  end

  defp merge(report, _run_report, state) do
    %{
      report
      | moves: report.moves + state.moves,
        affordances: merge_affordances(report.affordances, state.observed),
        transitions: Enum.uniq(report.transitions ++ MapSet.to_list(state.transitions)),
        coverage: Map.merge(report.coverage, state.reached, fn _, a, b -> MapSet.union(a, b) end),
        inconclusive: Map.merge(report.inconclusive, state.inconclusive, fn _, a, b -> a + b end),
        skipped: Map.merge(report.skipped, state.skipped, fn _, a, b -> a + b end)
    }
  end

  defp merge_affordances(a, b) do
    Map.merge(a, b, fn _, x, y ->
      Map.merge(x, y, fn
        :seen, m, n -> m + n
        _actor, m, n -> Map.merge(m, n, fn _, i, j -> i + j end)
      end)
    end)
  end

  # ---------------------------------------------------------------------------
  # Records and references

  # Records get stable references by the order they appear in a run
  # (`{Resource, 0}` is the first one seen), so a trace replays on a fresh
  # store whose ids differ.
  defp discover(state, ctx) do
    {refs, stamps} =
      for resource <- ctx.all, reduce: {state.refs, state.stamps} do
        {refs, stamps} ->
          known = Map.get(refs, resource, [])
          records = read_all(resource)
          ids = Enum.map(records, & &1.id)
          {Map.put(refs, resource, known ++ Enum.reject(ids, &(&1 in known))), Enum.reduce(records, stamps, &stamp(&2, &1, state.offset))}
      end

    %{state | refs: refs, stamps: stamps}
  end

  # Time moves by an offset, but a record created or changed after the clock
  # moved has a real timestamp: its own clock starts from the offset of the
  # moment it was last seen changing.
  defp stamp(stamps, record, offset) do
    written = Map.get(record, :updated_at) || Map.get(record, :inserted_at)

    case Map.get(stamps, record.id) do
      {^written, _} -> stamps
      _ -> Map.put(stamps, record.id, {written, offset})
    end
  end

  defp clock(state) do
    fn record ->
      {_, since} = Map.get(state.stamps, record.id, {nil, state.offset})
      DateTime.add(DateTime.utc_now(), state.offset - since, :second)
    end
  end

  defp read_all(resource) do
    sort = Enum.find([:inserted_at, :created_at], &Ash.Resource.Info.attribute(resource, &1))

    resource
    |> Ash.Query.new()
    |> then(&if(sort, do: Ash.Query.sort(&1, [{sort, :asc}]), else: &1))
    |> Ash.Query.limit(200)
    |> Ash.read!(authorize?: false)
    |> then(&if(sort, do: &1, else: Enum.sort_by(&1, fn r -> to_string(r.id) end)))
  rescue
    _ -> []
  end

  defp ref_of(state, resource, id), do: {resource, Enum.find_index(Map.get(state.refs, resource, []), &(&1 == id))}

  defp record(state, {resource, index}) when is_integer(index) do
    with id when not is_nil(id) <- Enum.at(Map.get(state.refs, resource, []), index),
         {:ok, record} <- Ash.get(resource, id, authorize?: false) do
      record
    else
      _ -> nil
    end
  end

  defp record(_state, _ref), do: nil

  defp records(state, resource) do
    for index <- 0..(length(Map.get(state.refs, resource, [])) - 1)//1, record = record(state, {resource, index}), do: record
  end

  defp resolve(state, {:ref, resource, index}), do: Enum.at(Map.get(state.refs, resource, []), index)
  defp resolve(state, {:actor, name}), do: state.actors |> Map.get(name) |> then(&(&1 && Map.get(&1, :id)))
  defp resolve(state, map) when is_map(map) and not is_struct(map), do: Map.new(map, fn {k, v} -> {k, resolve(state, v)} end)
  defp resolve(_state, value), do: value

  # ---------------------------------------------------------------------------
  # Choosing a move

  defp choose(ctx, state) do
    candidates = candidates(ctx, state)
    {roll, rand} = :rand.uniform_s(state.rand)
    state = %{state | rand: rand}

    cond do
      candidates == [] and ctx.clock == [] ->
        {nil, state}

      roll < ctx.probe and probes(ctx, state) != [] ->
        {probe, state} = pick(state, probes(ctx, state))
        with_params(ctx, state, probe)

      true ->
        pool = candidates ++ Enum.map(ctx.clock, &%{kind: :clock, by: &1})

        if pool == [] do
          {nil, state}
        else
          {move, state} = pick(state, pool)
          with_params(ctx, state, move)
        end
    end
  end

  defp candidates(ctx, state) do
    for {name, actor} <- Enum.sort_by(state.actors, &to_string(elem(&1, 0))), move <- actor_moves(ctx, state, name, actor), do: move
  end

  defp actor_moves(ctx, state, name, actor) do
    own =
      for resource <- ctx.resources, record <- records(state, resource), offered <- safe_offered(record, actor) do
        case String.split(offered, ".", parts: 2) do
          [verb] ->
            if performable?(ctx, resource, String.to_existing_atom(verb)),
              do: [%{kind: :verb, actor: name, ref: ref_of(state, resource, record.id), verb: String.to_existing_atom(verb)}],
              else: []

          [type, verb] ->
            child_start(ctx, state, name, record, type, verb)
        end
      end
      |> List.flatten()

    started =
      for qualified <- safe_available(ctx.domains, actor),
          [type, verb] = String.split(qualified, ".", parts: 2),
          resource = Enum.find(ctx.resources, &(Mana.Entity.type(&1) == type)),
          resource,
          verb = String.to_existing_atom(verb),
          performable?(ctx, resource, verb),
          do: %{kind: :start, actor: name, resource: resource, verb: verb, parent: nil}

    own ++ started ++ from_parents(ctx, state, name, actor)
  end

  # A collection verb `from: {Parent, field}` is offered by the parent; when
  # the parent is not explored itself, its records still offer the start.
  defp from_parents(ctx, state, name, actor) do
    for resource <- ctx.resources,
        verb <- Mana.Verbs.declared(resource),
        verb.collection and verb.from != nil,
        {parent, _field} = verb.from,
        parent not in ctx.resources,
        performable?(ctx, resource, verb.name),
        record <- records(state, parent),
        "#{Mana.Entity.type(resource)}.#{verb.name}" in safe_offered(record, actor),
        do: %{kind: :start, actor: name, resource: resource, verb: verb.name, parent: ref_of(state, parent, record.id)}
  end

  defp child_start(ctx, state, name, parent, type, verb) do
    with child when not is_nil(child) <- Enum.find(ctx.all, &(Mana.Entity.type(&1) == type)),
         verb = String.to_existing_atom(verb),
         true <- performable?(ctx, child, verb) do
      [%{kind: :start, actor: name, resource: child, verb: verb, parent: ref_of(state, parent.__struct__, parent.id)}]
    else
      _ -> []
    end
  end

  defp performable?(ctx, resource, verb_name) do
    case find_verb(resource, verb_name) do
      nil -> false
      verb -> ctx.external == :run or (is_nil(verb.external) and verb.risk != :money)
    end
  end

  defp probes(ctx, state) do
    if :refusal_enforced in ctx.properties do
      for {name, actor} <- Enum.sort_by(state.actors, &to_string(elem(&1, 0))),
          resource <- ctx.resources,
          record <- records(state, resource),
          offered = safe_offered(record, actor),
          verb <- Mana.Verbs.declared(resource),
          not verb.collection and not verb.idempotent and not is_nil(verb.when),
          to_string(verb.name) not in offered,
          performable?(ctx, resource, verb.name),
          do: %{kind: :probe, actor: name, ref: ref_of(state, resource, record.id), verb: verb.name}
    else
      []
    end
  end

  defp safe_offered(record, actor) do
    Mana.Verbs.offered(record, actor)
  rescue
    _ -> []
  end

  defp safe_available(domains, actor) do
    Mana.Verbs.available(domains, actor)
  rescue
    _ -> []
  end

  defp pick(state, list) do
    {index, rand} = :rand.uniform_s(length(list), state.rand)
    {Enum.at(list, index - 1), %{state | rand: rand}}
  end

  defp with_params(_ctx, state, %{kind: :clock} = move), do: {move, state}

  defp with_params(ctx, state, move) do
    resource = move_resource(move)
    action = Ash.Resource.Info.action(resource, Mana.Verbs.action(find_verb(resource, move.verb)))
    {params, state} = generate(ctx, state, resource, action, move)
    {Map.put(move, :params, params), state}
  end

  defp move_resource(%{resource: resource}), do: resource
  defp move_resource(%{ref: {resource, _}}), do: resource

  defp find_verb(resource, name), do: Enum.find(Mana.Verbs.declared(resource), &(&1.name == name))

  # ---------------------------------------------------------------------------
  # Inputs

  defp generate(ctx, state, resource, action, move) do
    references = references(resource, action)
    {fixed, state} = pick_references(state, references)

    fixed =
      case move do
        %{kind: :start, parent: {parent, index}} ->
          verb = find_verb(resource, move.verb)
          {_parent, field} = verb.from
          Map.put(fixed, field, {:ref, parent, index})

        _ ->
          fixed
      end

    overrides = Map.get(ctx.generators, {resource, action.name}, %{})
    {seed, rand} = :rand.uniform_s(1_000_000_000, state.rand)
    {size, rand} = :rand.uniform_s(30, rand)

    generated =
      try do
        resource
        |> Ash.Generator.action_input(action.name, Map.merge(Map.new(fixed, fn {k, _} -> {k, nil} end), overrides))
        |> StreamData.resize(size)
        |> StreamData.seeded(seed)
        |> Enum.at(0)
      rescue
        _ -> %{}
      end

    {Map.merge(generated, fixed), %{state | rand: rand}}
  end

  defp references(resource, action) do
    inputs = MapSet.new(Map.get(action, :accept, []) ++ Enum.map(Map.get(action, :arguments, []), & &1.name))

    for relationship <- Ash.Resource.Info.relationships(resource),
        relationship.type == :belongs_to,
        relationship.source_attribute in inputs,
        do: {relationship.source_attribute, relationship.destination}
  end

  defp pick_references(state, references) do
    Enum.reduce(references, {%{}, state}, fn {field, destination}, {fixed, state} ->
      choices =
        Enum.map(0..(length(Map.get(state.refs, destination, [])) - 1)//1, &{:ref, destination, &1}) ++
          for({name, actor} <- Enum.sort_by(state.actors, &to_string(elem(&1, 0))), is_struct(actor, destination), do: {:actor, name})

      if choices == [] do
        {fixed, state}
      else
        {choice, state} = pick(state, choices)
        {Map.put(fixed, field, choice), state}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Performing and checking

  defp perform_and_check(ctx, state, move) do
    state = %{state | trace: state.trace ++ [move], moves: state.moves + 1}

    state =
      case move do
        %{kind: :clock} -> advance(ctx, state, move.by)
        %{kind: :probe} -> probe(ctx, state, move)
        %{kind: :start} -> start(ctx, state, move)
        %{kind: :verb} -> verb_move(ctx, state, move)
      end

    state = discover(state, ctx)
    if state.violations == [], do: check_state(ctx, state), else: state
  end

  defp actor(state, name), do: Map.get(state.actors, name)

  defp verb_move(ctx, state, move) do
    case record(state, move.ref) do
      nil ->
        bump(state, :inconclusive, :record_gone)

      before ->
        resource = before.__struct__
        verb = find_verb(resource, move.verb)
        actor = actor(state, move.actor)

        case perform(before, verb, resolve(state, move.params), actor) do
          {:ok, after_record} ->
            state = reached(state, resource, verb.name)
            state = transition(state, before, after_record, move)

            state
            |> check_flow_monotonic(ctx, before, after_record, move)
            |> check_idempotent(ctx, before, after_record, verb, move)
            |> check_inverse(ctx, before, after_record, verb, move)

          {:error, kind, detail} ->
            judge_offered_failure(ctx, state, kind, detail, resource, verb, move)
        end
    end
  end

  defp start(ctx, state, move) do
    verb = find_verb(move.resource, move.verb)
    actor = actor(state, move.actor)

    case perform(move.resource, verb, resolve(state, move.params), actor) do
      {:ok, _record} -> reached(state, move.resource, verb.name)
      {:error, kind, detail} -> judge_offered_failure(ctx, state, kind, detail, move.resource, verb, move)
    end
  end

  defp judge_offered_failure(ctx, state, kind, detail, resource, verb, move) do
    if kind in [:forbidden, :unavailable, :raised] and :offer_honest in ctx.properties do
      violate(state, :offer_honest, resource, verb.name, move.actor, "offered, then #{kind_text(kind)}: #{detail}")
    else
      bump(state, :inconclusive, {:refused, kind})
    end
  end

  defp kind_text(:forbidden), do: "refused by policy"
  defp kind_text(:unavailable), do: "refused by its own when"
  defp kind_text(:raised), do: "crashed"
  defp kind_text(kind), do: to_string(kind)

  defp probe(_ctx, state, move) do
    case record(state, move.ref) do
      nil ->
        state

      record ->
        resource = record.__struct__
        verb = find_verb(resource, move.verb)

        # The offer may have changed since the probe was chosen.
        if to_string(verb.name) in safe_offered(record, actor(state, move.actor)) do
          bump(state, :inconclusive, :probe_now_offered)
        else
          case perform(record, verb, resolve(state, move.params), actor(state, move.actor)) do
            {:ok, _} ->
              violate(state, :refusal_enforced, resource, verb.name, move.actor, "not offered, yet the server performed it")

            {:error, _kind, _detail} ->
              state
          end
        end
    end
  end

  defp perform(%{__struct__: resource} = record, verb, params, actor) do
    action = Ash.Resource.Info.action(resource, Mana.Verbs.action(verb))
    opts = [actor: actor, context: %{mana_explore: true}]

    result =
      case action.type do
        :update ->
          record |> Ash.Changeset.for_update(action.name, params, opts) |> Ash.update()

        :destroy ->
          case record |> Ash.Changeset.for_destroy(action.name, params, opts) |> Ash.destroy(return_destroyed?: true) do
            {:ok, destroyed} -> {:ok, %{destroyed | __meta__: :destroyed}}
            other -> other
          end
      end

    classify(result, params)
  rescue
    error -> {:error, :raised, Exception.message(error)}
  end

  defp perform(resource, verb, params, actor) when is_atom(resource) do
    action = Ash.Resource.Info.action(resource, Mana.Verbs.action(verb))
    opts = [actor: actor, context: %{mana_explore: true}]

    result =
      case action.type do
        :create -> resource |> Ash.Changeset.for_create(action.name, params, opts) |> Ash.create()
        :action -> resource |> Ash.ActionInput.for_action(action.name, params, opts) |> Ash.run_action() |> then(&if(&1 == :ok, do: {:ok, nil}, else: &1))
      end

    classify(result, params)
  rescue
    error -> {:error, :raised, Exception.message(error)}
  end

  defp classify({:ok, record}, _params), do: {:ok, record}

  defp classify({:error, error}, params) do
    errors = error |> Ash.Error.to_error_class() |> Map.get(:errors, []) |> List.flatten()
    inputs = params |> Map.keys() |> MapSet.new(&to_string/1)

    cond do
      Enum.any?(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1)) or match?(%Ash.Error.Forbidden{}, error) and not Enum.any?(errors, &match?(%Mana.Error{}, &1)) ->
        {:error, :forbidden, first_message(errors, error)}

      Enum.any?(errors, &unavailable?/1) ->
        {:error, :unavailable, first_message(errors, error)}

      Enum.any?(errors, &match?(%Mana.Error{}, &1)) ->
        {:error, :domain, first_message(errors, error)}

      Enum.all?(errors, &input_error?(&1, inputs)) and errors != [] ->
        {:error, :input, first_message(errors, error)}

      match?(%Ash.Error.Invalid{}, Ash.Error.to_error_class(error)) ->
        {:error, :invalid, first_message(errors, error)}

      true ->
        {:error, :raised, first_message(errors, error)}
    end
  end

  defp unavailable?(%Mana.Error{code: code}), do: is_binary(code) and (code == "verb.unavailable" or String.ends_with?(code, "unavailable") or code == "flow.step_not_reached")
  defp unavailable?(_), do: false

  defp input_error?(%{field: field}, inputs) when not is_nil(field), do: MapSet.member?(inputs, to_string(field))
  defp input_error?(%{fields: [_ | _] = fields}, inputs), do: Enum.any?(fields, &MapSet.member?(inputs, to_string(&1)))
  defp input_error?(%Ash.Error.Changes.Required{}, _), do: true
  defp input_error?(%Ash.Error.Invalid.NoSuchInput{}, _), do: true
  defp input_error?(_, _), do: false

  defp first_message([first | _], _), do: Exception.message(first) |> String.slice(0, 240)
  defp first_message([], error), do: Exception.message(error) |> String.slice(0, 240)

  defp check_flow_monotonic(state, ctx, before, after_record, move) do
    resource = before.__struct__

    if :flow_monotonic in ctx.properties and Mana.Flow in Spark.extensions(resource) and alive?(after_record) do
      ahead = Mana.Flow.position(before)
      now = Mana.Flow.position(after_record)
      outside = Spark.Dsl.Extension.get_opt(resource, [:flow], :before, [])

      if Map.get(before, Mana.Flow.cursor(resource)) not in outside and now.index < ahead.index and not now.done,
        do: violate(state, :flow_monotonic, resource, move.verb, move.actor, "cursor moved back from #{ahead.step} to #{now.step}"),
        else: state
    else
      state
    end
  end

  defp check_idempotent(state, ctx, _before, after_record, verb, move) do
    if :idempotent in ctx.properties and verb.idempotent and alive?(after_record) and state.violations == [] do
      case perform(after_record, verb, resolve(state, move.params), actor(state, move.actor)) do
        {:ok, again} ->
          case changed(after_record, again) do
            [] -> state
            fields -> violate(state, :idempotent, after_record.__struct__, verb.name, move.actor, "a second time changed #{Enum.join(fields, ", ")}")
          end

        {:error, kind, detail} ->
          violate(state, :idempotent, after_record.__struct__, verb.name, move.actor, "a second time was #{kind}: #{detail}")
      end
    else
      state
    end
  end

  defp check_inverse(state, ctx, before, after_record, verb, move) do
    inverse = verb.inverse && find_verb(before.__struct__, verb.inverse)

    with true <- :inverse_restores in ctx.properties and state.violations == [],
         %{} <- inverse,
         true <- alive?(after_record),
         actor = actor(state, move.actor),
         true <- to_string(inverse.name) in safe_offered(after_record, actor),
         {coin, rand} = :rand.uniform_s(state.rand),
         state = %{state | rand: rand},
         true <- if(state.replaying, do: Map.get(move, :then_inverse) == true, else: coin < 0.5) do
      state = %{state | trace: List.update_at(state.trace, -1, &Map.put(&1, :then_inverse, true))}
      touched = changed(before, after_record)

      case perform(after_record, inverse, %{}, actor) do
        {:ok, restored} ->
          state = reached(state, before.__struct__, inverse.name)

          case Enum.reject(touched, &(Map.get(restored, &1) == Map.get(before, &1))) do
            [] -> state
            fields -> violate(state, :inverse_restores, before.__struct__, verb.name, move.actor, "#{inverse.name} left #{Enum.join(fields, ", ")} changed")
          end

        {:error, kind, detail} ->
          violate(state, :inverse_restores, before.__struct__, verb.name, move.actor, "#{inverse.name} was offered, then #{kind}: #{detail}")
      end
    else
      _ -> state
    end
  end

  defp alive?(%{__meta__: :destroyed}), do: false
  defp alive?(nil), do: false
  defp alive?(_), do: true

  defp changed(a, b) do
    for attribute <- Ash.Resource.Info.public_attributes(a.__struct__),
        attribute.name not in @timestamps,
        Map.get(a, attribute.name) != Map.get(b, attribute.name),
        do: attribute.name
  end

  # ---------------------------------------------------------------------------
  # Time

  defp advance(ctx, state, by) do
    seconds = Mana.Reconcile.within_seconds(by)
    state = %{state | offset: state.offset + seconds}
    now = clock(state)

    fired =
      for resource <- ctx.all,
          Mana.Entity in Spark.extensions(resource),
          deadline <- Mana.Entity.deadlines(resource),
          record <- records(state, resource),
          Mana.Entity.holds?(deadline.when, record),
          due?(deadline, record, now.(record), seconds) do
        Mana.Entity.run_deadline(resource, record.id, to_string(deadline.name))
        {resource, deadline.name}
      end

    Enum.reduce(fired, state, fn {resource, name}, state -> reached(state, resource, {:deadline, name}) end)
  end

  defp due?(%{after: {amount, unit}}, record, now, advanced) when is_integer(amount) do
    wait = Mana.Reconcile.within_seconds({amount, unit})

    case Map.get(record, :updated_at) || Map.get(record, :inserted_at) do
      %DateTime{} = at -> DateTime.diff(now, at, :second) >= wait
      _ -> advanced >= wait
    end
  end

  defp due?(deadline, record, now, _advanced) do
    case Mana.Entity.due_at(deadline, record) do
      %DateTime{} = at -> DateTime.compare(at, now) != :gt
      _ -> false
    end
  rescue
    _ -> false
  end

  # ---------------------------------------------------------------------------
  # Whole-state checks

  defp check_state(ctx, state) do
    state
    |> check_rules(ctx)
    |> check_deadlock(ctx)
  end

  defp check_rules(state, ctx) do
    now = clock(state)

    for resource <- ctx.resources,
        Mana.Reconcile in Spark.extensions(resource),
        rule <- Mana.Reconcile.declared(resource),
        rule.name not in ctx.skip_rules,
        property = if(rule.within, do: :eventually, else: :invariant),
        property in ctx.properties,
        reduce: state do
      state ->
        if state.violations != [] do
          state
        else
          case Enum.find(observe_rule(resource, rule, now), &(&1.rule == rule.name)) do
            %{state: :converged} -> state
            nil -> state
            report -> violate(state, property, resource, rule.name, nil, "#{rule.describe}: #{Enum.map_join(report.diverging, "; ", & &1.detail)}")
          end
        end
    end
  end

  defp observe_rule(resource, rule, now) do
    Mana.Reconcile.observe(resource, now: now) |> Enum.filter(&(&1.rule == rule.name))
  rescue
    _ -> []
  end

  defp check_deadlock(state, ctx) do
    if :flow_deadlock in ctx.properties and state.violations == [] do
      Enum.reduce_while(ctx.resources, state, fn resource, state ->
        if Mana.Flow in Spark.extensions(resource) do
          case Enum.find(records(state, resource), &deadlocked?(state, resource, &1)) do
            nil -> {:cont, state}
            record -> {:halt, violate(state, :flow_deadlock, resource, nil, nil, "stuck at #{Map.get(record, Mana.Flow.cursor(resource))}: no one is offered its step's verb")}
          end
        else
          {:cont, state}
        end
      end)
    else
      state
    end
  end

  defp deadlocked?(state, resource, record) do
    cursor = Map.get(record, Mana.Flow.cursor(resource))
    step = Enum.find(Mana.Flow.steps(resource), &(&1.name == cursor))
    outside = Spark.Dsl.Extension.get_opt(resource, [:flow], :before, [])

    step_verbs = if step, do: for(verb <- Mana.Verbs.declared(resource), Mana.Verbs.action(verb) == step.action, not verb.collection, do: to_string(verb.name)), else: []

    step != nil and cursor not in outside and not Mana.Flow.position(record).done and step_verbs != [] and
      Enum.all?(state.actors, fn {_, actor} -> MapSet.disjoint?(MapSet.new(safe_offered(record, actor)), MapSet.new(step_verbs)) end) and
      not (Mana.Entity in Spark.extensions(resource) and Enum.any?(Mana.Entity.deadlines(resource), &Mana.Entity.holds?(&1.when, record)))
  end

  defp check_history(ctx, state) do
    if :history_replays in ctx.properties do
      Enum.reduce_while(ctx.resources, state, fn resource, state ->
        log = Mana.History in Spark.extensions(resource) && Mana.History.log(resource)

        if log do
          case Enum.find_value(records(state, resource), &replay_mismatch(state, resource, log, &1)) do
            nil -> {:cont, state}
            detail -> {:halt, violate(state, :history_replays, resource, nil, nil, detail)}
          end
        else
          {:cont, state}
        end
      end)
    else
      state
    end
  end

  defp replay_mismatch(state, resource, log, record) do
    entries = Mana.History.export(log, Mana.Entity.type(resource), record.id)
    by_id = for {_name, actor} <- state.actors, is_map(actor), Map.has_key?(actor, :id), into: %{}, do: {to_string(actor.id), actor}

    case Mana.History.replay(resource, entries, actor: &Map.get(by_id, to_string(&1)), times: :as_recorded) do
      {:ok, nil, _} ->
        nil

      {:ok, rebuilt, _} ->
        fields = changed(record, rebuilt) |> Enum.reject(&(&1 == :id))

        try do
          Ash.destroy!(rebuilt, authorize?: false)
        rescue
          _ -> :ok
        end

        if fields != [], do: "#{Mana.Entity.type(resource)} #{record.id}: replaying its history rebuilt #{Enum.join(fields, ", ")} differently"

      {:error, %{error: reason}} when reason in [:external, :redacted_input] ->
        nil

      {:error, %{at: at, action: action}} ->
        "#{Mana.Entity.type(resource)} #{record.id}: replay stopped at entry #{at} (#{action})"
    end
  rescue
    error -> "#{Mana.Entity.type(resource)} #{record.id}: replay crashed: #{Exception.message(error) |> String.slice(0, 200)}"
  end

  # ---------------------------------------------------------------------------
  # Affordances

  @doc "A record's shape: its atom, boolean and enum fields, as `\"field=value\"` joined by commas."
  def shape(record) do
    resource = record.__struct__

    resource
    |> Ash.Resource.Info.public_attributes()
    |> Enum.filter(&shape_type?(&1.type))
    |> Enum.sort_by(& &1.name)
    |> Enum.map_join(",", &"#{&1.name}=#{inspect_value(Map.get(record, &1.name))}")
  end

  defp shape_type?(type) when type in [Ash.Type.Atom, Ash.Type.Boolean], do: true
  defp shape_type?(type) when is_atom(type), do: Code.ensure_loaded?(type) and function_exported?(type, :values, 0)
  defp shape_type?(_), do: false

  defp inspect_value(nil), do: "nil"
  defp inspect_value(value), do: to_string(value)

  defp observe_affordances(ctx, state) do
    observed =
      for resource <- ctx.resources, record <- records(state, resource), reduce: state.observed do
        observed ->
          key = {Mana.Entity.type(resource), shape(record)}

          entry =
            for {name, actor} <- state.actors, reduce: Map.get(observed, key, %{seen: 0}) do
              entry ->
                counts = Map.get(entry, name, %{})
                counts = Enum.reduce(safe_offered(record, actor), counts, fn verb, counts -> Map.update(counts, verb, 1, &(&1 + 1)) end)
                Map.put(entry, name, counts)
            end

          Map.put(observed, key, Map.update!(entry, :seen, &(&1 + 1)))
      end

    %{state | observed: observed}
  end

  defp transition(state, before, after_record, move) do
    from = shape(before)
    to = if alive?(after_record), do: shape(after_record), else: "destroyed"
    edge = %{resource: Mana.Entity.type(before.__struct__), from: from, to: to, verb: to_string(move.verb), actor: to_string(move.actor)}
    %{state | transitions: MapSet.put(state.transitions, edge)}
  end

  defp reached(state, resource, verb), do: %{state | reached: Map.update(state.reached, resource, MapSet.new([verb]), &MapSet.put(&1, verb))}

  defp coverage(ctx, report) do
    for resource <- ctx.resources, into: %{} do
      declared = resource |> Mana.Verbs.declared() |> Enum.map(& &1.name)
      reached = report.coverage |> Map.get(resource, MapSet.new()) |> Enum.filter(&is_atom/1)
      skipped = Enum.reject(declared, &performable?(ctx, resource, &1))

      {resource, %{declared: declared, reached: Enum.sort(reached), never: Enum.sort((declared -- reached) -- skipped), skipped: skipped}}
    end
  end

  # ---------------------------------------------------------------------------
  # Violations and shrinking

  defp violate(state, property, resource, verb, actor, detail) do
    violation = %Violation{property: property, resource: resource, verb: verb, actor: actor, detail: detail, trace: state.trace}
    %{state | violations: state.violations ++ [violation]}
  end

  defp bump(state, bucket, key), do: Map.update!(state, bucket, &Map.update(&1, key, 1, fn n -> n + 1 end))

  defp shrink(%{shrink: false}, violation), do: violation

  defp shrink(ctx, violation) do
    original = length(violation.trace)

    # The original trace is replayed first: a violation that does not
    # reproduce from a fresh store is reported as found, unshrunk.
    if fails_same?(ctx, violation, violation.trace) do
      {trace, _attempts} = reduce(ctx, violation, violation.trace, 2, 0)
      {%{violations: [found | _]}, _} = replay_moves(ctx, trace, ctx.seed)
      %{found | shrunk_from: original}
    else
      violation
    end
  end

  defp reduce(_ctx, _violation, trace, _n, attempts) when length(trace) <= 1 or attempts > 120, do: {trace, attempts}

  defp reduce(ctx, violation, trace, n, attempts) do
    size = max(div(length(trace), n), 1)
    chunks = Enum.chunk_every(Enum.with_index(trace), size)

    {smaller, attempts} =
      Enum.reduce_while(chunks, {nil, attempts}, fn chunk, {nil, attempts} ->
        drop = MapSet.new(chunk, &elem(&1, 1))
        candidate = for {move, index} <- Enum.with_index(trace), index not in drop, do: move

        if fails_same?(ctx, violation, candidate),
          do: {:halt, {candidate, attempts + 1}},
          else: {:cont, {nil, attempts + 1}}
      end)

    cond do
      smaller -> reduce(ctx, violation, smaller, max(n - 1, 2), attempts)
      size == 1 -> {trace, attempts}
      true -> reduce(ctx, violation, trace, min(n * 2, length(trace)), attempts)
    end
  end

  defp fails_same?(ctx, violation, moves) do
    case replay_moves(ctx, moves, ctx.seed) do
      {%{violations: [found | _]}, _} -> found.property == violation.property and found.resource == violation.resource and found.verb == violation.verb
      _ -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Reports

  @doc "An AVP verdict of `report`: one criterion per property, failed by its violations."
  def verdict(subject, %Report{} = report) do
    criteria =
      for property <- @properties do
        found = Enum.filter(report.violations, &(&1.property == property))

        %{
          "criterion" => to_string(property),
          "status" => if(found == [], do: "pass", else: "fail"),
          "reason" => if(found != [], do: Enum.map_join(found, "; ", & &1.detail)),
          "evidence" => Enum.map(found, &trace_json/1)
        }
      end

    passed = Enum.count(criteria, &(&1["status"] == "pass"))

    %{
      "subject" => subject,
      "outcome" => if(passed == length(criteria) and report.moves > 0, do: "pass", else: if(report.moves == 0, do: "inconclusive", else: "fail")),
      "acceptanceScore" => passed / length(criteria),
      "criteria" => criteria
    }
  end

  @doc "A person's reading of `report`."
  def format(%Report{} = report) do
    head = "explored #{report.runs} runs, #{report.moves} moves (seed #{report.seed})"

    violations =
      for v <- report.violations do
        steps = Enum.map_join(v.trace, " → ", &describe_move/1)
        "✗ #{v.property} #{inspect(v.resource)}#{if v.verb, do: ".#{v.verb}"}#{if v.actor, do: " as #{v.actor}"}: #{v.detail}\n  #{steps}" <>
          if(v.shrunk_from, do: "\n  (shrunk from #{v.shrunk_from} moves)", else: "")
      end

    never =
      for {resource, %{never: [_ | _] = never}} <- report.coverage,
          do: "· #{inspect(resource)} never reached: #{Enum.join(never, ", ")}"

    Enum.join([head] ++ if(violations == [], do: ["✓ no property broken"], else: violations) ++ never, "\n")
  end

  @doc false
  def describe_move(%{kind: :clock, by: {n, unit}}), do: "clock +#{n}#{String.first(to_string(unit))}"
  def describe_move(%{kind: :probe} = move), do: "#{move.actor} tries #{type(move.ref)}.#{move.verb}"
  def describe_move(%{kind: :start} = move), do: "#{move.actor}.#{Mana.Entity.type(move.resource)}.#{move.verb}"
  def describe_move(%{kind: :verb} = move), do: "#{move.actor}.#{type(move.ref)}.#{move.verb}#{if move[:then_inverse], do: " (and back)"}"

  defp type({resource, index}), do: "#{Mana.Entity.type(resource)}##{index}"

  @doc "Writes `violation`'s trace as JSON under `dir`; answers the path."
  def save(%Violation{} = violation, dir) do
    File.mkdir_p!(dir)
    name = "#{violation.property}-#{Mana.Entity.type(violation.resource)}#{if violation.verb, do: "-#{violation.verb}"}"
    path = Path.join(dir, "#{name}.json")
    File.write!(path, Jason.encode!(trace_json(violation), pretty: true))
    path
  end

  defp trace_json(violation) do
    %{
      "property" => to_string(violation.property),
      "resource" => inspect(violation.resource),
      "verb" => violation.verb && to_string(violation.verb),
      "actor" => violation.actor && to_string(violation.actor),
      "detail" => violation.detail,
      "moves" => Enum.map(violation.trace, &move_json/1)
    }
  end

  defp move_json(move) do
    move
    |> Map.new(fn
      {:ref, {resource, index}} -> {"ref", [inspect(resource), index]}
      {:resource, resource} -> {"resource", inspect(resource)}
      {:parent, nil} -> {"parent", nil}
      {:parent, {resource, index}} -> {"parent", [inspect(resource), index]}
      {:by, {n, unit}} -> {"by", [n, to_string(unit)]}
      {:params, params} -> {"params", Map.new(params, fn {k, v} -> {to_string(k), value_json(v)} end)}
      {key, value} when is_atom(value) -> {to_string(key), value && to_string(value)}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp value_json({:ref, resource, index}), do: %{"ref" => [inspect(resource), index]}
  defp value_json({:actor, name}), do: %{"actor" => to_string(name)}
  defp value_json(value), do: Mana.History.encode(value)

  @doc """
  Rebuilds the situation a saved trace (`save/2`) reaches, without checking
  anything: what a Moment's backend recipe calls. `actors` are the people by
  the names the trace uses. Answers the records by reference
  (`%{{Resource, 0} => record}`).
  """
  def replay_file(path, domains, actors) do
    moves = path |> File.read!() |> Jason.decode!() |> Map.fetch!("moves") |> Enum.map(&move_from_json/1)
    ctx = context(domains, actors: actors, reset: fn _ -> :ok end, properties: [])

    with_quiet_deadlines(fn ->
      state = %{new_state(ctx, 0) | actors: actors}

      state =
        Enum.reduce(moves, state, fn move, state ->
          state = %{state | trace: state.trace ++ [move]}

          state =
            case move do
              %{kind: :clock} -> advance(ctx, state, move.by)
              %{kind: :probe} -> state
              %{kind: :start} -> start(ctx, state, move)
              %{kind: :verb} -> verb_move(ctx, state, move)
            end

          discover(state, ctx)
        end)

      for {resource, ids} <- state.refs, {_id, index} <- Enum.with_index(ids), record = record(state, {resource, index}), into: %{}, do: {{resource, index}, record}
    end)
  end

  defp move_from_json(json) do
    kind = String.to_existing_atom(json["kind"])

    base = %{kind: kind}

    base
    |> put_some(:actor, json["actor"] && String.to_atom(json["actor"]))
    |> put_some(:verb, json["verb"] && String.to_existing_atom(json["verb"]))
    |> put_some(:ref, ref_from_json(json["ref"]))
    |> put_some(:resource, json["resource"] && module(json["resource"]))
    |> Map.put(:parent, ref_from_json(json["parent"]))
    |> put_some(:by, json["by"] && {hd(json["by"]), String.to_existing_atom(List.last(json["by"]))})
    |> put_some(:then_inverse, json["then_inverse"])
    |> Map.put(:params, Map.new(json["params"] || %{}, fn {k, v} -> {String.to_existing_atom(k), param_from_json(v)} end))
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp ref_from_json([resource, index]), do: {module(resource), index}
  defp ref_from_json(_), do: nil

  defp param_from_json(%{"ref" => [resource, index]}), do: {:ref, module(resource), index}
  defp param_from_json(%{"actor" => name}), do: {:actor, String.to_atom(name)}
  defp param_from_json(value), do: value

  defp module(name), do: name |> String.trim_leading("Elixir.") |> String.split(".") |> Module.safe_concat()
end
