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

  A record's log is replayed with the original set aside, together with
  the records that reference it, every entry in the order it was recorded
  (`Mana.History.replay_all/2`); a record whose log starts with an update
  (written outside its actions) is seeded from its row before that update.

  A violation is shrunk to the shortest sequence of moves that still breaks
  the same property and kept in the report with that trace. `save/3` writes
  it as a file, `replay_file/3` (a Moment's backend recipe) rebuilds the
  situation it reaches, and `check/3` replays it to tell whether the
  property still breaks there. Verbs that are `external:` or move money are
  never performed unless `external: :run`.

  A run is deterministic for a `seed`: records get references in the order
  the run met them, and records met together (a setup's, a move's side
  effects) are ordered by what they hold, never by a timestamp or an id; a
  deadline after a wait falls on the run's clock, counted from when the run
  saw the record change. Generated inputs come from the seed; a
  `generators:` function that reads the clock or randomness of its own
  makes the run depend on it.

  A saved trace is a Moment: `mix mana.explore --save <name>` writes it to
  `priv/moments/explorations/<name>.json`, a `moments` section that declares
  `explorations "priv/moments/explorations"` (`Moments.Extension`) exports
  every trace there as a Moment of its app, and `moments suite <name>` runs
  `check/3` in a database of its own: it fails while the bug is there and
  passes once it is fixed.

  The report also carries coverage (verbs declared, reached, never reached)
  and the affordance graph: for each record *shape* — its atom, boolean and
  enum fields — the verbs each actor was offered there, and the transitions
  between shapes. `Mana.Explore.Lock` writes it as `affordances.json`.

  What it cannot use is decided once per resource and reported, not
  logged per move: a resource with no primary read is not explored
  (`report.unexplored`, with the reason), and a part that raises (an offer,
  an input, a deadline, a rule) is counted in `report.skipped` with its
  error. `format/1` lists both.

  Stores: ETS resources are emptied between runs; any other data layer needs
  `reset:` (a function), e.g. a fresh `Mana.Snapshot` scope per run.
  """
  require Ash.Query

  alias Ash.DataLayer.Ets
  alias Spark.Dsl.Extension

  @properties [
    :offer_honest,
    :refusal_enforced,
    :idempotent,
    :inverse_restores,
    :invariant,
    :eventually,
    :flow_monotonic,
    :flow_deadlock,
    :history_replays
  ]
  @timestamps [:inserted_at, :updated_at, :created_at]

  defmodule Violation do
    @moduledoc false
    @derive {Inspect, except: [:trace]}
    defstruct [
      :property,
      :resource,
      :verb,
      :actor,
      :detail,
      trace: [],
      shrunk_from: nil,
      run: nil,
      explored: nil
    ]
  end

  defmodule Report do
    @moduledoc false
    defstruct seed: nil,
              runs: 0,
              moves: 0,
              violations: [],
              coverage: %{},
              affordances: %{},
              transitions: [],
              inconclusive: %{},
              skipped: %{},
              unexplored: %{}
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
        Enum.reduce(
          1..ctx.runs,
          {%Report{seed: ctx.seed}, MapSet.new()},
          &explore_run(ctx, &1, &2)
        )

      ctx.reset.(:done)
      %{report | runs: ctx.runs, coverage: coverage(ctx, report), unexplored: ctx.unexplored}
    end)
  end

  defp explore_run(ctx, index, {report, seen}) do
    {state, run_report} = run_once(ctx, ctx.seed + index)
    report = merge(report, run_report, state)

    {violations, seen} =
      for violation <- state.violations, reduce: {report.violations, seen} do
        {acc, seen} -> keep_first(ctx, violation, index, acc, seen)
      end

    {%{report | violations: violations}, seen}
  end

  defp keep_first(ctx, violation, index, acc, seen) do
    key = {violation.property, violation.resource, violation.verb}

    if MapSet.member?(seen, key),
      do: {acc, seen},
      else:
        {acc ++ [%{shrink(ctx, violation) | run: index, explored: explored(ctx)}],
         MapSet.put(seen, key)}
  end

  # What a replay must check again to judge the same promise the same way.
  defp explored(ctx),
    do: %{resources: ctx.resources, skip_rules: Enum.sort(ctx.skip_rules)}

  @doc """
  A `reset:` for apps on Postgres: every run gets a fresh `Mana.Snapshot`
  scope cloned from `from` (the migrated base, or a named snapshot; `opts`
  go to `Mana.Snapshot.open/3`), the
  previous one is dropped, and this process uses it (exploration turns Ash's
  async loads off while it runs, so none escapes the scope).
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
      found =
        ctx |> replay_moves(moves, ctx.seed) |> elem(0) |> Map.get(:violations) |> List.first()

      ctx.reset.(:done)
      found
    end)
  end

  # ---------------------------------------------------------------------------
  # Setup

  defp context(domains, opts) do
    domains = List.wrap(domains)

    every =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          uniq: true,
          do: resource

    # Records are found and fetched through the primary read; a resource
    # without one is left out of the run, once, instead of failing each read.
    {all, unreadable} = Enum.split_with(every, &Ash.Resource.Info.primary_action(&1, :read))
    explored = opts[:resources] || Enum.filter(all, &(Mana.Verbs in Spark.extensions(&1)))

    %{
      domains: domains,
      all: all,
      resources: Enum.filter(explored, &(&1 in all)),
      unexplored: Map.new(unreadable, &{&1, "no primary read action"}),
      parents: parents(explored, all),
      runs: option(opts, :runs, 50),
      depth: option(opts, :depth, 10),
      seed: opts[:seed] || :erlang.phash2(make_ref()),
      clock: opts[:clock] || default_clock(explored),
      properties: MapSet.new(option(opts, :properties, @properties)),
      skip_rules: MapSet.new(option(opts, :skip_rules, [])),
      generators: option(opts, :generators, %{}),
      external: option(opts, :external, :skip),
      reset: opts[:reset] || (&default_reset(every, &1)),
      setup: opts[:setup] || default_setup(opts[:actors]),
      shrink: Keyword.get(opts, :shrink, true),
      probe: Keyword.get(opts, :probe, 0.25)
    }
  end

  defp option(opts, key, default), do: opts[key] || default

  # Resources a collection verb starts from (`from: {Parent, field}`) without
  # being explored themselves: their records offer the start.
  defp parents(explored, all) do
    for resource <- explored,
        verb <- Mana.Verbs.declared(resource),
        verb.collection and verb.from != nil,
        {parent, _field} = verb.from,
        parent not in explored and parent in all,
        uniq: true,
        do: parent
  end

  defp default_setup(actors), do: fn -> actors || %{anyone: nil} end

  defp default_clock(resources) do
    deadlines =
      for resource <- resources,
          Mana.Entity in Spark.extensions(resource),
          deadline <- Mana.Entity.deadlines(resource),
          match?({n, _} when is_integer(n), deadline.after),
          do: deadline.after

    timed =
      for resource <- resources,
          Mana.Reconcile in Spark.extensions(resource),
          rule <- Mana.Reconcile.declared(resource),
          match?({n, _} when is_integer(n), rule.within),
          do: rule.within

    # Windows read from a setting ({Module, :fun}) are not known here: give
    # those apps clock: explicitly.
    (deadlines ++ timed) |> Enum.uniq() |> Enum.map(fn {n, unit} -> {n + 1, unit} end)
  end

  defp default_reset(_resources, :done), do: :ok

  defp default_reset(resources, _run) do
    for resource <- resources do
      if Ash.DataLayer.data_layer(resource) == Ets do
        empty_ets(resource)
      else
        raise ArgumentError,
              "#{inspect(resource)} is not on ETS; give Mana.Explore a reset: function (e.g. a fresh Mana.Snapshot scope)"
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
    owner =
      Process.whereis(Module.concat(Ets.Info.table(resource), Ets.TableManager))

    ref = owner && Process.monitor(owner)
    Ets.stop(resource)

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
  # Async loads would run in other processes, outside the run's data scope
  # and out of its order: exploration is sequential.
  defp with_quiet_deadlines(fun) do
    previous = Application.get_env(:mana_core, :deadline_inserter)
    async = Application.fetch_env(:ash, :disable_async?)
    Application.put_env(:mana_core, :deadline_inserter, fn _ -> :ok end)
    Application.put_env(:ash, :disable_async?, true)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:mana_core, :deadline_inserter, previous),
        else: Application.delete_env(:mana_core, :deadline_inserter)

      case async do
        {:ok, value} -> Application.put_env(:ash, :disable_async?, value)
        :error -> Application.delete_env(:ash, :disable_async?)
      end
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
      stamps: %{},
      seen: %{},
      offers: %{},
      available: %{}
    }
    |> discover(ctx)
    |> survey(ctx)
  end

  defp run_once(ctx, seed) do
    state = new_state(ctx, seed)

    state =
      Enum.reduce_while(1..ctx.depth, state, fn _, state -> explore_step(ctx, state) end)

    state = if state.violations == [], do: check_history(ctx, state), else: state
    {state, nil}
  end

  defp replay_moves(ctx, moves, seed) do
    state = %{new_state(ctx, seed) | replaying: true}

    state =
      Enum.reduce_while(moves, state, fn move, state ->
        ctx |> perform_and_check(state, move) |> until_violated()
      end)

    state = if state.violations == [], do: check_history(ctx, state), else: state
    {state, nil}
  end

  defp explore_step(ctx, state) do
    state = observe_affordances(ctx, state)

    case choose(ctx, state) do
      {nil, state} -> {:halt, state}
      {move, state} -> ctx |> perform_and_check(state, move) |> until_violated()
    end
  end

  defp until_violated(%{violations: []} = state), do: {:cont, state}
  defp until_violated(state), do: {:halt, state}

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

  defp merge_affordances(a, b),
    do: Map.merge(a, b, fn _, x, y -> Map.merge(x, y, &merge_counts/3) end)

  defp merge_counts(:seen, m, n), do: m + n
  defp merge_counts(_actor, m, n), do: Map.merge(m, n, fn _, i, j -> i + j end)

  # ---------------------------------------------------------------------------
  # Records and references

  # Records get stable references by the order they appear in a run
  # (`{Resource, 0}` is the first one seen), so a trace replays on a fresh
  # store whose ids differ. Records that appear together (a setup's, a
  # move's side effects) are ordered by what they hold, never by when or
  # under which id they were written: a timestamp of second precision ties
  # and the store then answers ties in its own order, ids are random, and
  # either would make the same seed act on another record.
  defp discover(state, ctx) do
    Enum.reduce(ctx.all, state, fn resource, state ->
      {records, state} = read_all(state, resource)
      known = Map.get(state.refs, resource, [])
      seen = MapSet.new(known)
      ids = known_ids(state)

      new =
        records
        |> Enum.reject(&MapSet.member?(seen, &1.id))
        |> Enum.sort_by(&content(&1, ids))
        |> Enum.map(& &1.id)

      %{
        state
        | refs: Map.put(state.refs, resource, known ++ new),
          stamps: Enum.reduce(records, state.stamps, &stamp(&2, &1, state.offset))
      }
    end)
  end

  # A record as the run sees it: its attributes, without its key and the
  # ones the store fills from the clock or at random (a function default),
  # times as one value, a known record's or actor's id as its reference and
  # any other id as one value.
  defp content(%resource{} = record, ids) do
    for attribute <- Ash.Resource.Info.attributes(resource),
        not attribute.primary_key?,
        not generated?(attribute.default) and not generated?(attribute.update_default),
        do: {attribute.name, neutral(Map.get(record, attribute.name), ids)}
  end

  defp generated?(default), do: is_function(default) or match?({_, _, _}, default)

  defp known_ids(state) do
    refs =
      for {resource, ids} <- state.refs,
          {id, index} <- Enum.with_index(ids),
          into: %{},
          do: {to_string(id), {:ref, resource, index}}

    for {name, actor} <- state.actors,
        is_map(actor) and Map.has_key?(actor, :id),
        into: refs,
        do: {to_string(actor.id), {:actor, name}}
  end

  defp neutral(%type{}, _ids) when type in [DateTime, NaiveDateTime, Time], do: :time

  defp neutral(value, ids) when is_binary(value) do
    cond do
      Map.has_key?(ids, value) -> ids[value]
      match?({:ok, _}, Ecto.UUID.cast(value)) -> :id
      true -> value
    end
  end

  defp neutral(%_{} = value, ids), do: value |> Map.from_struct() |> neutral(ids)

  defp neutral(value, ids) when is_map(value),
    do: value |> Enum.map(fn {key, inner} -> {key, neutral(inner, ids)} end) |> Enum.sort()

  defp neutral(value, ids) when is_list(value), do: Enum.map(value, &neutral(&1, ids))
  defp neutral(value, _ids), do: value

  # The record a start move created is the next one of its resource, before
  # anything its creation made alongside it.
  defp register(state, %resource{id: id}) do
    known = Map.get(state.refs, resource, [])
    if id in known, do: state, else: %{state | refs: Map.put(state.refs, resource, known ++ [id])}
  end

  defp register(state, _result), do: state

  # What each actor is offered on every record a move can start from, and
  # the collection verbs it may start, asked once per state: choosing a
  # move, probing, the affordances and the deadlock check read it.
  defp survey(state, ctx) do
    state = %{state | seen: %{}, offers: %{}, available: %{}}

    state =
      for resource <- ctx.resources ++ ctx.parents, reduce: state do
        state ->
          records = records(state, resource)
          state = %{state | seen: Map.put(state.seen, resource, records)}

          for record <- records, {name, actor} <- state.actors, reduce: state do
            state ->
              {offered, state} = offered_now(state, record, actor)
              %{state | offers: Map.put(state.offers, {resource, record.id, name}, offered)}
          end
      end

    for {name, actor} <- state.actors, reduce: state do
      state ->
        {available, state} = available_now(state, ctx.domains, actor)
        %{state | available: Map.put(state.available, name, available)}
    end
  end

  defp seen(state, resource), do: Map.get(state.seen, resource, [])

  defp offered(state, record, name),
    do: Map.get(state.offers, {record.__struct__, record.id, name}, [])

  # Time moves by an offset, but a record created or changed after the clock
  # moved has a real timestamp: its own clock starts from the offset of the
  # moment it was last seen changing.
  # Any change counts, not only a timestamp: one with second precision does
  # not move when two moves land in the same second.
  defp stamp(stamps, record, offset) do
    written =
      record
      |> Map.take(Enum.map(Ash.Resource.Info.attributes(record.__struct__), & &1.name))
      |> :erlang.phash2()

    case Map.get(stamps, record.id) do
      {^written, _} -> stamps
      _ -> Map.put(stamps, record.id, {written, offset})
    end
  end

  defp elapsed(state, record) do
    {_, since} = Map.get(state.stamps, record.id, {nil, state.offset})
    state.offset - since
  end

  defp clock(state) do
    fn record ->
      {_, since} = Map.get(state.stamps, record.id, {nil, state.offset})
      DateTime.add(DateTime.utc_now(), state.offset - since, :second)
    end
  end

  # The oldest 200 are read; `discover` orders them.
  defp read_all(state, resource) do
    sort = Enum.find([:inserted_at, :created_at], &Ash.Resource.Info.attribute(resource, &1))

    records =
      resource
      |> Ash.Query.new()
      |> then(&if(sort, do: Ash.Query.sort(&1, [{sort, :asc}]), else: &1))
      |> Ash.Query.limit(200)
      |> Ash.read!(authorize?: false)

    {records, state}
  rescue
    error -> {[], skip(state, "reading #{inspect(resource)}", error)}
  end

  defp ref_of(state, resource, id),
    do: {resource, Enum.find_index(Map.get(state.refs, resource, []), &(&1 == id))}

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
    for index <- 0..(length(Map.get(state.refs, resource, [])) - 1)//1,
        record = record(state, {resource, index}),
        do: record
  end

  defp resolve(state, {:ref, resource, index}),
    do: Enum.at(Map.get(state.refs, resource, []), index)

  defp resolve(state, {:actor, name}),
    do: state.actors |> Map.get(name) |> then(&(&1 && Map.get(&1, :id)))

  defp resolve(state, map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, resolve(state, v)} end)

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
    for name <- state.actors |> Map.keys() |> Enum.sort_by(&to_string/1),
        move <- actor_moves(ctx, state, name),
        do: move
  end

  defp actor_moves(ctx, state, name) do
    own =
      for resource <- ctx.resources,
          record <- seen(state, resource),
          offered <- offered(state, record, name) do
        offered_moves(ctx, state, name, resource, record, offered)
      end
      |> List.flatten()

    started =
      for qualified <- Map.get(state.available, name, []),
          [type, verb] = String.split(qualified, ".", parts: 2),
          resource = Enum.find(ctx.resources, &(Mana.Entity.type(&1) == type)),
          resource,
          verb = String.to_existing_atom(verb),
          performable?(ctx, resource, verb),
          do: %{kind: :start, actor: name, resource: resource, verb: verb, parent: nil}

    own ++ started ++ from_parents(ctx, state, name)
  end

  defp offered_moves(ctx, state, name, resource, record, offered) do
    case String.split(offered, ".", parts: 2) do
      [verb] -> own_move(ctx, state, name, resource, record, String.to_existing_atom(verb))
      [type, verb] -> child_start(ctx, state, name, record, type, verb)
    end
  end

  defp own_move(ctx, state, name, resource, record, verb) do
    if performable?(ctx, resource, verb),
      do: [%{kind: :verb, actor: name, ref: ref_of(state, resource, record.id), verb: verb}],
      else: []
  end

  # A collection verb `from: {Parent, field}` is offered by the parent; when
  # the parent is not explored itself, its records still offer the start.
  defp from_parents(ctx, state, name) do
    for resource <- ctx.resources,
        verb <- Mana.Verbs.declared(resource),
        verb.collection and verb.from != nil,
        {parent, _field} = verb.from,
        parent not in ctx.resources,
        performable?(ctx, resource, verb.name),
        record <- seen(state, parent),
        "#{Mana.Entity.type(resource)}.#{verb.name}" in offered(state, record, name),
        do: %{
          kind: :start,
          actor: name,
          resource: resource,
          verb: verb.name,
          parent: ref_of(state, parent, record.id)
        }
  end

  defp child_start(ctx, state, name, parent, type, verb) do
    with child when not is_nil(child) <-
           Enum.find(ctx.resources, &(Mana.Entity.type(&1) == type)),
         verb = String.to_existing_atom(verb),
         true <- performable?(ctx, child, verb) do
      [
        %{
          kind: :start,
          actor: name,
          resource: child,
          verb: verb,
          parent: ref_of(state, parent.__struct__, parent.id)
        }
      ]
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
      for name <- state.actors |> Map.keys() |> Enum.sort_by(&to_string/1),
          resource <- ctx.resources,
          record <- seen(state, resource),
          offered = offered(state, record, name),
          verb <- Mana.Verbs.declared(resource),
          not verb.collection and not verb.idempotent and not is_nil(verb.when),
          to_string(verb.name) not in offered,
          performable?(ctx, resource, verb.name),
          do: %{
            kind: :probe,
            actor: name,
            ref: ref_of(state, resource, record.id),
            verb: verb.name
          }
    else
      []
    end
  end

  defp offered_now(state, record, actor) do
    {Mana.Verbs.offered(record, actor), state}
  rescue
    error -> {[], skip(state, "the verbs offered on #{inspect(record.__struct__)}", error)}
  end

  defp available_now(state, domains, actor) do
    {Mana.Verbs.available(domains, actor), state}
  rescue
    error -> {[], skip(state, "the verbs available", error)}
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

    {generated, state} =
      try do
        resource
        |> Ash.Generator.action_input(
          action.name,
          Map.merge(Map.new(fixed, fn {k, _} -> {k, nil} end), overrides)
        )
        |> StreamData.resize(size)
        |> StreamData.seeded(seed)
        |> Enum.at(0)
        |> then(&{&1, state})
      rescue
        error ->
          {%{}, skip(state, "generating input for #{inspect(resource)}.#{action.name}", error)}
      end

    {Map.merge(generated, fixed), %{state | rand: rand}}
  end

  defp references(resource, action) do
    inputs =
      MapSet.new(
        Map.get(action, :accept, []) ++ Enum.map(Map.get(action, :arguments, []), & &1.name)
      )

    for relationship <- Ash.Resource.Info.relationships(resource),
        relationship.type == :belongs_to,
        relationship.source_attribute in inputs,
        do: {relationship.source_attribute, relationship.destination}
  end

  defp pick_references(state, references) do
    Enum.reduce(references, {%{}, state}, fn {field, destination}, {fixed, state} ->
      choices =
        Enum.map(
          0..(length(Map.get(state.refs, destination, [])) - 1)//1,
          &{:ref, destination, &1}
        ) ++
          for(
            {name, actor} <- Enum.sort_by(state.actors, &to_string(elem(&1, 0))),
            is_struct(actor, destination),
            do: {:actor, name}
          )

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

    state = state |> discover(ctx) |> survey(ctx)
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
      {:ok, record} ->
        state |> register(record) |> reached(move.resource, verb.name)

      {:error, kind, detail} ->
        judge_offered_failure(ctx, state, kind, detail, move.resource, verb, move)
    end
  end

  defp judge_offered_failure(ctx, state, kind, detail, resource, verb, move) do
    if kind in [:forbidden, :unavailable, :raised] and :offer_honest in ctx.properties do
      violate(
        state,
        :offer_honest,
        resource,
        verb.name,
        move.actor,
        "offered, then #{kind_text(kind)}: #{detail}"
      )
    else
      bump(
        state,
        :inconclusive,
        {:refused, kind, "#{Mana.Entity.type(resource)}.#{verb.name}",
         String.slice(detail, 0, 120)}
      )
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
        probe_record(state, record, move)
    end
  end

  defp probe_record(state, record, move) do
    resource = record.__struct__
    verb = find_verb(resource, move.verb)
    actor = actor(state, move.actor)

    # A replayed probe was chosen in another run: the offer may differ here.
    if to_string(verb.name) in offered(state, record, move.actor) do
      bump(state, :inconclusive, :probe_now_offered)
    else
      record
      |> perform(verb, resolve(state, move.params), actor)
      |> judge_probe(state, resource, verb, move)
    end
  end

  defp judge_probe({:ok, _}, state, resource, verb, move) do
    violate(
      state,
      :refusal_enforced,
      resource,
      verb.name,
      move.actor,
      "not offered, yet the server performed it"
    )
  end

  defp judge_probe({:error, _kind, _detail}, state, _resource, _verb, _move), do: state

  defp perform(%{__struct__: resource} = record, verb, params, actor) do
    action = Ash.Resource.Info.action(resource, Mana.Verbs.action(verb))
    opts = [actor: actor, context: %{mana_explore: true}]

    result =
      case action.type do
        :update ->
          record |> Ash.Changeset.for_update(action.name, params, opts) |> Ash.update()

        :destroy ->
          case record
               |> Ash.Changeset.for_destroy(action.name, params, opts)
               |> Ash.destroy(return_destroyed?: true) do
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
        :create ->
          resource |> Ash.Changeset.for_create(action.name, params, opts) |> Ash.create()

        :action ->
          resource
          |> Ash.ActionInput.for_action(action.name, params, opts)
          |> Ash.run_action()
          |> then(&if(&1 == :ok, do: {:ok, nil}, else: &1))
      end

    classify(result, params)
  rescue
    error -> {:error, :raised, Exception.message(error)}
  end

  defp classify({:ok, record}, _params), do: {:ok, record}

  defp classify({:error, error}, params) do
    errors = error |> Ash.Error.to_error_class() |> Map.get(:errors, []) |> List.flatten()
    inputs = params |> Map.keys() |> MapSet.new(&to_string/1)
    {:error, error_kind(error, errors, inputs), first_message(errors, error)}
  end

  defp error_kind(error, errors, inputs) do
    cond do
      forbidden?(error, errors) -> :forbidden
      Enum.any?(errors, &unavailable?/1) -> :unavailable
      Enum.any?(errors, &match?(%Mana.Error{}, &1)) -> :domain
      Enum.all?(errors, &input_error?(&1, inputs)) and errors != [] -> :input
      match?(%Ash.Error.Invalid{}, Ash.Error.to_error_class(error)) -> :invalid
      true -> :raised
    end
  end

  defp forbidden?(error, errors) do
    Enum.any?(errors, &match?(%Ash.Error.Forbidden.Policy{}, &1)) or
      (match?(%Ash.Error.Forbidden{}, error) and
         not Enum.any?(errors, &match?(%Mana.Error{}, &1)))
  end

  defp unavailable?(%Mana.Error{code: code}),
    do:
      is_binary(code) and
        (code == "verb.unavailable" or String.ends_with?(code, "unavailable") or
           code == "flow.step_not_reached")

  defp unavailable?(_), do: false

  defp input_error?(%{field: field}, inputs) when not is_nil(field),
    do: MapSet.member?(inputs, to_string(field))

  defp input_error?(%{fields: [_ | _] = fields}, inputs),
    do: Enum.any?(fields, &MapSet.member?(inputs, to_string(&1)))

  defp input_error?(%Ash.Error.Changes.Required{}, _), do: true
  defp input_error?(%Ash.Error.Invalid.NoSuchInput{}, _), do: true
  defp input_error?(_, _), do: false

  defp first_message([first | _], _), do: Exception.message(first) |> String.slice(0, 240)
  defp first_message([], error), do: Exception.message(error) |> String.slice(0, 240)

  defp check_flow_monotonic(state, ctx, before, after_record, move) do
    resource = before.__struct__

    if :flow_monotonic in ctx.properties and Mana.Flow in Spark.extensions(resource) and
         alive?(after_record) do
      ahead = Mana.Flow.position(before)
      now = Mana.Flow.position(after_record)
      outside = Extension.get_opt(resource, [:flow], :before, [])

      if Map.get(before, Mana.Flow.cursor(resource)) not in outside and now.index < ahead.index and
           not now.done,
         do:
           violate(
             state,
             :flow_monotonic,
             resource,
             move.verb,
             move.actor,
             "cursor moved back from #{ahead.step} to #{now.step}"
           ),
         else: state
    else
      state
    end
  end

  defp check_idempotent(state, ctx, _before, after_record, verb, move) do
    if :idempotent in ctx.properties and verb.idempotent and alive?(after_record) and
         state.violations == [] do
      after_record
      |> perform(verb, resolve(state, move.params), actor(state, move.actor))
      |> judge_again(state, after_record, verb, move)
    else
      state
    end
  end

  defp judge_again({:ok, again}, state, after_record, verb, move) do
    case changed(after_record, again) do
      [] ->
        state

      fields ->
        violate(
          state,
          :idempotent,
          after_record.__struct__,
          verb.name,
          move.actor,
          "a second time changed #{Enum.join(fields, ", ")}"
        )
    end
  end

  defp judge_again({:error, kind, detail}, state, after_record, verb, move) do
    violate(
      state,
      :idempotent,
      after_record.__struct__,
      verb.name,
      move.actor,
      "a second time was #{kind}: #{detail}"
    )
  end

  defp check_inverse(state, ctx, before, after_record, verb, move) do
    inverse = verb.inverse && find_verb(before.__struct__, verb.inverse)

    with true <- :inverse_restores in ctx.properties and state.violations == [],
         %{} <- inverse,
         true <- alive?(after_record) do
      actor = actor(state, move.actor)
      {offered, state} = offered_now(state, after_record, actor)

      if to_string(inverse.name) in offered,
        do: maybe_invert(state, before, after_record, {verb, inverse}, actor, move),
        else: state
    else
      _ -> state
    end
  end

  defp maybe_invert(state, before, after_record, verbs, actor, move) do
    {coin, rand} = :rand.uniform_s(state.rand)
    state = %{state | rand: rand}

    if if(state.replaying, do: Map.get(move, :then_inverse) == true, else: coin < 0.5) do
      state = %{state | trace: List.update_at(state.trace, -1, &Map.put(&1, :then_inverse, true))}
      invert(state, before, after_record, verbs, actor, move)
    else
      state
    end
  end

  defp invert(state, before, after_record, {verb, inverse}, actor, move) do
    touched = changed(before, after_record)

    case perform(after_record, inverse, %{}, actor) do
      {:ok, restored} ->
        state
        |> reached(before.__struct__, inverse.name)
        |> judge_restored(before, restored, touched, {verb, inverse}, move)

      {:error, kind, detail} ->
        violate(
          state,
          :inverse_restores,
          before.__struct__,
          verb.name,
          move.actor,
          "#{inverse.name} was offered, then #{kind}: #{detail}"
        )
    end
  end

  defp judge_restored(state, before, restored, touched, {verb, inverse}, move) do
    case Enum.reject(touched, &(Map.get(restored, &1) == Map.get(before, &1))) do
      [] ->
        state

      fields ->
        violate(
          state,
          :inverse_restores,
          before.__struct__,
          verb.name,
          move.actor,
          "#{inverse.name} left #{Enum.join(fields, ", ")} changed"
        )
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

    for resource <- ctx.all,
        Mana.Entity in Spark.extensions(resource),
        deadline <- Mana.Entity.deadlines(resource),
        record <- records(state, resource),
        Mana.Entity.holds?(deadline.when, record),
        reduce: state do
      state ->
        case due(deadline, record, now.(record), elapsed(state, record)) do
          {:ok, true} ->
            Mana.Entity.run_deadline(resource, record.id, to_string(deadline.name))
            reached(state, resource, {:deadline, deadline.name})

          {:ok, false} ->
            state

          {:error, error} ->
            skip(state, "a deadline of #{inspect(resource)}", error)
        end
    end
  end

  # A deadline after a wait counts on the run's clock from when the run saw
  # the record last change, never on its stored timestamps: how long the run
  # took for real, or a timestamp of second precision, would decide it.
  defp due(%{after: {amount, unit}}, _record, _now, elapsed) when is_integer(amount),
    do: {:ok, elapsed >= Mana.Reconcile.within_seconds({amount, unit})}

  defp due(deadline, record, now, _elapsed) do
    case Mana.Entity.due_at(deadline, record) do
      %DateTime{} = at -> {:ok, DateTime.compare(at, now) != :gt}
      _ -> {:ok, false}
    end
  rescue
    error -> {:error, error}
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
      state -> check_rule(state, resource, rule, property, now)
    end
  end

  defp check_rule(%{violations: [_ | _]} = state, _resource, _rule, _property, _now), do: state

  defp check_rule(state, resource, rule, property, now) do
    {observed, state} = observe_rule(state, resource, rule, now)

    case Enum.find(observed, &(&1.rule == rule.name)) do
      %{state: :converged} ->
        state

      nil ->
        state

      report ->
        violate(
          state,
          property,
          resource,
          rule.name,
          nil,
          "#{rule.describe}: #{Enum.map_join(report.diverging, "; ", & &1.detail)}"
        )
    end
  end

  defp observe_rule(state, resource, rule, now) do
    {Mana.Reconcile.observe(resource, now: now) |> Enum.filter(&(&1.rule == rule.name)), state}
  rescue
    error -> {[], skip(state, "rule #{rule.name} of #{inspect(resource)}", error)}
  end

  defp check_deadlock(state, ctx) do
    if :flow_deadlock in ctx.properties and state.violations == [] do
      Enum.reduce_while(ctx.resources, state, &check_resource_deadlock/2)
    else
      state
    end
  end

  defp check_resource_deadlock(resource, state) do
    if Mana.Flow in Spark.extensions(resource) do
      case Enum.find(seen(state, resource), &deadlocked?(state, resource, &1)) do
        nil ->
          {:cont, state}

        record ->
          {:halt,
           violate(
             state,
             :flow_deadlock,
             resource,
             nil,
             nil,
             "stuck at #{Map.get(record, Mana.Flow.cursor(resource))}: no one is offered its step's verb"
           )}
      end
    else
      {:cont, state}
    end
  end

  defp deadlocked?(state, resource, record) do
    cursor = Map.get(record, Mana.Flow.cursor(resource))
    step = Enum.find(Mana.Flow.steps(resource), &(&1.name == cursor))
    outside = Extension.get_opt(resource, [:flow], :before, [])

    step_verbs =
      if step,
        do:
          for(
            verb <- Mana.Verbs.declared(resource),
            Mana.Verbs.action(verb) == step.action,
            not verb.collection,
            do: to_string(verb.name)
          ),
        else: []

    step != nil and cursor not in outside and not Mana.Flow.position(record).done and
      step_verbs != [] and
      Enum.all?(Map.keys(state.actors), fn name ->
        MapSet.disjoint?(MapSet.new(offered(state, record, name)), MapSet.new(step_verbs))
      end) and
      not (Mana.Entity in Spark.extensions(resource) and
             Enum.any?(Mana.Entity.deadlines(resource), &Mana.Entity.holds?(&1.when, record)))
  end

  defp check_history(ctx, state) do
    if :history_replays in ctx.properties do
      Enum.reduce_while(ctx.resources, state, &check_resource_history(ctx, &1, &2))
    else
      state
    end
  end

  defp check_resource_history(ctx, resource, state) do
    if history_log(resource) do
      Enum.reduce_while(records(state, resource), {:cont, state}, fn record, {_, state} ->
        ctx |> replay_mismatch(state, resource, record) |> judge_history(state, resource)
      end)
    else
      {:cont, state}
    end
  end

  # For both reductions: this record's, and the resources' around it.
  defp judge_history(nil, state, _resource), do: {:cont, {:cont, state}}

  defp judge_history({:inconclusive, reason}, state, resource) do
    key = {:history_not_rebuilt, Mana.Entity.type(resource), reason}
    {:cont, {:cont, bump(state, :inconclusive, key)}}
  end

  defp judge_history(detail, state, resource),
    do: {:halt, {:halt, violate(state, :history_replays, resource, nil, nil, detail)}}

  # The record is rebuilt where it no longer is: the original is set aside
  # first, so the rebuild meets none of its identities (a unique key the
  # original holds, an upsert that would land on it and change it) and the
  # comparison is between the record and its log alone. The records that
  # reference it go aside with it (the database would refuse to remove it
  # under them) and are rebuilt with it, every entry in the order it was
  # recorded, since a step of the record may need one of theirs (publishing
  # a place once its service is published). Where the data layer transacts,
  # setting aside and rebuilding happen in a transaction rolled back after
  # the comparison, as `Mana.Replay` does. Elsewhere the rebuilt records and
  # the entries they logged are removed and the originals put back as they
  # were.
  defp replay_mismatch(ctx, state, resource, record) do
    if Ash.DataLayer.data_layer_can?(resource, :transact),
      do: rolled_back(ctx, state, resource, record),
      else: put_back(ctx, state, record)
  end

  defp rolled_back(ctx, state, resource, record) do
    case Ash.DataLayer.transaction([resource], fn ->
           Ash.DataLayer.rollback([resource], {:checked, aside(ctx, state, record)})
         end) do
      {:error, {:checked, outcome}} -> outcome
      other -> "#{name(state, record)}: replay transaction: #{inspect(other)}"
    end
  end

  defp aside(ctx, state, record) do
    case set_aside(ctx, record, {MapSet.new(), []}, true) do
      {:ok, {_keys, aside}} -> rebuilt_differently(state, record, aside)
      {:error, reason} -> {:inconclusive, reason}
    end
  end

  # Depth first: what references a record goes before it, so `aside` lists
  # the records in the order they were removed.
  defp set_aside(ctx, %resource{} = record, {keys, aside}, transaction?) do
    key = {resource, Map.take(record, Ash.Resource.Info.primary_key(resource))}

    if MapSet.member?(keys, key) do
      {:ok, {keys, aside}}
    else
      with {:ok, {keys, aside}} <-
             set_aside_all(
               ctx,
               referencing(ctx, record),
               {MapSet.put(keys, key), aside},
               transaction?
             ),
           :ok <- remove(record, transaction?),
           do: {:ok, {keys, aside ++ [record]}}
    end
  end

  defp set_aside_all(ctx, records, acc, transaction?) do
    Enum.reduce_while(records, {:ok, acc}, fn record, {:ok, acc} ->
      case set_aside(ctx, record, acc, transaction?) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        error -> {:halt, error}
      end
    end)
  end

  defp referencing(ctx, %resource{} = record) do
    for {dependent, field, key} <- dependents(ctx, resource),
        value = Map.get(record, key),
        not is_nil(value),
        found <-
          dependent
          |> Ash.Query.do_filter([{field, value}])
          |> Ash.read!(authorize?: false),
        do: found
  end

  # `{resource, its field, the referenced field}` for every relationship that
  # names `resource`'s records from a resource of the run.
  defp dependents(ctx, resource) do
    named =
      for dependent <- ctx.all,
          %{type: :belongs_to, destination: ^resource} = relationship <-
            Ash.Resource.Info.relationships(dependent),
          do: {dependent, relationship.source_attribute, relationship.destination_attribute}

    owned =
      for relationship <- Ash.Resource.Info.relationships(resource),
          relationship.type in [:has_one, :has_many, :many_to_many],
          not Map.get(relationship, :no_attributes?, false),
          is_nil(Map.get(relationship, :manual)),
          dependent = Map.get(relationship, :through) || relationship.destination,
          dependent in ctx.all,
          do: {dependent, owning_field(relationship), relationship.source_attribute}

    Enum.uniq(named ++ owned)
  end

  defp owning_field(%{type: :many_to_many} = relationship),
    do: relationship.source_attribute_on_join_resource

  defp owning_field(relationship), do: relationship.destination_attribute

  # Straight through the data layer: no action runs, so nothing is logged or
  # announced about a record that is only out of the way. Inside the check's
  # transaction a record outside it (another repo) is never removed.
  defp remove(%resource{} = record, transaction? \\ false) do
    if transaction? and not Ash.DataLayer.in_transaction?(resource),
      do: {:error, "#{inspect(resource)} is outside the check's transaction"},
      else: destroy(record)
  end

  defp destroy(%resource{} = record) do
    case Ash.DataLayer.destroy(resource, Ash.Changeset.new(record)) do
      :ok ->
        :ok

      {:error, error} ->
        {:error,
         "#{inspect(resource)} could not be set aside: #{error |> Ash.Error.to_ash_error() |> Exception.message() |> String.slice(0, 160)}"}
    end
  end

  defp put_back(ctx, state, record) do
    case set_aside(ctx, record, {MapSet.new(), []}, false) do
      {:ok, {_keys, aside}} ->
        known = aside |> Enum.flat_map(&logged/1) |> MapSet.new(& &1.id)

        try do
          rebuilt_differently(state, record, aside, &remove_rebuilt(&1, known))
        after
          aside |> Enum.reverse() |> Enum.each(&restore/1)
        end

      {:error, reason} ->
        {:inconclusive, reason}
    end
  end

  defp remove_rebuilt(rebuilt, known) do
    for record <- rebuilt do
      remove(record)
      for entry <- logged(record), not MapSet.member?(known, entry.id), do: remove(entry)
    end

    :ok
  end

  defp logged(%resource{} = record) do
    if log = history_log(resource) do
      type = Mana.Entity.type(resource)

      log
      |> Ash.Query.filter(subject_type == ^type and subject_id == ^to_string(record.id))
      |> Ash.read!(authorize?: false)
    else
      []
    end
  end

  defp history_log(resource),
    do: Mana.History in Spark.extensions(resource) && Mana.History.log(resource)

  # A rebuild that stopped half way may hold the original's key.
  defp restore(%resource{} = record) do
    key = Map.take(record, Ash.Resource.Info.primary_key(resource))

    case Ash.get(resource, key, authorize?: false) do
      {:ok, occupant} -> remove(occupant)
      _ -> :ok
    end

    attributes =
      Map.new(Ash.Resource.Info.attributes(resource), &{&1.name, Map.get(record, &1.name)})

    {:ok, _} =
      Ash.DataLayer.create(
        resource,
        resource |> Ash.Changeset.new() |> Ash.Changeset.force_change_attributes(attributes)
      )

    :ok
  end

  # The record first, then what went aside with it in the reverse of the
  # order it was removed (what a record references before it); a record
  # without history cannot be rebuilt and is only out of the way.
  defp rebuilt_differently(state, record, aside, cleanup \\ fn _ -> :ok end) do
    group = aside |> Enum.reverse() |> Enum.filter(&history_log(&1.__struct__))
    ids = Map.new(group, &{to_string(&1.id), key(&1)})
    histories = Enum.map(group, &history(&1, ids))
    entries = Enum.find(histories, &(&1.key == key(record))).entries

    by_id =
      for {_name, actor} <- state.actors,
          is_map(actor),
          Map.has_key?(actor, :id),
          into: %{},
          do: {to_string(actor.id), actor}

    case Mana.History.replay_all(histories,
           actor: &Map.get(by_id, to_string(&1)),
           params: fn _key, _action, params, rebuilt -> rebound(params, ids, rebuilt) end,
           times: :as_recorded,
           notify?: false
         ) do
      {:ok, rebuilt, _} ->
        cleanup.(Map.values(rebuilt))
        copy = rebuilt[key(record)]
        if copy, do: rebuilt_mismatch(state, record, copy, entries)

      {:error, %{error: reason}} when reason in [:external, :redacted_input] ->
        nil

      {:error, failure} ->
        stopped(state, record, failure)
    end
  rescue
    error ->
      "#{name(state, record)}: replay crashed: #{Exception.message(error) |> String.slice(0, 200)}"
  end

  defp key(%resource{} = record), do: {resource, record.id}

  defp history(%resource{} = record, ids) do
    entries = Mana.History.export(history_log(resource), Mana.Entity.type(resource), record.id)

    seed =
      if Mana.History.starts_with_update?(resource, entries) do
        now =
          Map.new(Ash.Resource.Info.attributes(resource), &{&1.name, Map.get(record, &1.name)})

        seed = Mana.History.seed_state(resource, record.id, now)
        &rebound(seed, ids, &1)
      end

    %{key: key(record), resource: resource, entries: entries, seed: seed}
  end

  # A value that named a record of the set names its rebuilt copy, once
  # there is one.
  defp rebound(value, ids, rebuilt) when is_binary(value) do
    case Map.fetch(ids, value) do
      {:ok, key} when is_map_key(rebuilt, key) -> to_string(rebuilt[key].id)
      _ -> value
    end
  end

  defp rebound(map, ids, rebuilt) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {field, value} -> {field, rebound(value, ids, rebuilt)} end)

  defp rebound(list, ids, rebuilt) when is_list(list),
    do: Enum.map(list, &rebound(&1, ids, rebuilt))

  defp rebound(value, _ids, _rebuilt), do: value

  defp stopped(state, record, %{key: {resource, id} = at_key, at: at, action: action} = failure) do
    of = if at_key == key(record), do: "", else: " of #{name(state, resource, id)}"

    "#{name(state, record)}: replay stopped at entry #{at}#{of} (#{action}): #{failure_reason(failure.error)}"
  end

  defp failure_reason(reason) when is_atom(reason), do: to_string(reason)
  defp failure_reason(error), do: Mana.History.error_code(error)

  # By reference (`booking#0`), not id: a detail reads the same in every run
  # of a seed.
  defp name(state, %resource{} = record), do: name(state, resource, record.id)

  defp name(state, resource, id) do
    case ref_of(state, resource, id) do
      {_, nil} -> "#{Mana.Entity.type(resource)} #{id}"
      ref -> type(ref)
    end
  end

  defp rebuilt_mismatch(state, record, rebuilt, entries) do
    # A time an action stamps from the clock (requested_at) is not
    # something a replay can reproduce; one that came in as input is.
    inputs =
      for entry <- entries,
          key <- Map.keys(entry["params"] || %{}),
          into: MapSet.new(),
          do: to_string(key)

    fields =
      record
      |> changed(rebuilt)
      |> Enum.reject(
        &(&1 == :id or
            (clock_value?(Map.get(record, &1)) and not MapSet.member?(inputs, to_string(&1))))
      )

    if fields != [],
      do:
        "#{name(state, record)}: replaying its history rebuilt #{Enum.join(fields, ", ")} differently"
  end

  # Exploration goes on past a part it cannot run; the report counts each
  # one, with its error, instead of a log line per attempt.
  defp skip(state, what, error) do
    reason =
      error |> Exception.message() |> String.split("\n", parts: 2) |> hd() |> String.slice(0, 200)

    bump(state, :skipped, "#{what}: #{reason}")
  end

  defp clock_value?(%DateTime{}), do: true
  defp clock_value?(%NaiveDateTime{}), do: true
  defp clock_value?(_), do: false

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

  defp shape_type?(type) when is_atom(type),
    do: Code.ensure_loaded?(type) and function_exported?(type, :values, 0)

  defp shape_type?(_), do: false

  defp inspect_value(nil), do: "nil"
  defp inspect_value(value), do: to_string(value)

  defp observe_affordances(ctx, state) do
    observed =
      for resource <- ctx.resources, record <- seen(state, resource), reduce: state.observed do
        observed ->
          key = {Mana.Entity.type(resource), shape(record)}

          entry =
            state.actors
            |> Map.keys()
            |> Enum.reduce(
              Map.get(observed, key, %{seen: 0}),
              &count_offers(state, record, &1, &2)
            )

          Map.put(observed, key, Map.update!(entry, :seen, &(&1 + 1)))
      end

    %{state | observed: observed}
  end

  defp count_offers(state, record, name, entry) do
    counts =
      Enum.reduce(offered(state, record, name), Map.get(entry, name, %{}), fn verb, counts ->
        Map.update(counts, verb, 1, &(&1 + 1))
      end)

    Map.put(entry, name, counts)
  end

  defp transition(state, before, after_record, move) do
    from = shape(before)
    to = if alive?(after_record), do: shape(after_record), else: "destroyed"

    edge = %{
      resource: Mana.Entity.type(before.__struct__),
      from: from,
      to: to,
      verb: to_string(move.verb),
      actor: to_string(move.actor)
    }

    %{state | transitions: MapSet.put(state.transitions, edge)}
  end

  defp reached(state, resource, verb),
    do: %{
      state
      | reached: Map.update(state.reached, resource, MapSet.new([verb]), &MapSet.put(&1, verb))
    }

  defp coverage(ctx, report) do
    for resource <- ctx.resources, into: %{} do
      declared = resource |> Mana.Verbs.declared() |> Enum.map(& &1.name)
      reached = report.coverage |> Map.get(resource, MapSet.new()) |> Enum.filter(&is_atom/1)
      skipped = Enum.reject(declared, &performable?(ctx, resource, &1))

      {resource,
       %{
         declared: declared,
         reached: Enum.sort(reached),
         never: Enum.sort((declared -- reached) -- skipped),
         skipped: skipped
       }}
    end
  end

  # ---------------------------------------------------------------------------
  # Violations and shrinking

  defp violate(state, property, resource, verb, actor, detail) do
    violation = %Violation{
      property: property,
      resource: resource,
      verb: verb,
      actor: actor,
      detail: detail,
      trace: state.trace
    }

    %{state | violations: state.violations ++ [violation]}
  end

  defp bump(state, bucket, key),
    do: Map.update!(state, bucket, &Map.update(&1, key, 1, fn n -> n + 1 end))

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

  defp reduce(_ctx, _violation, trace, _n, attempts) when length(trace) <= 1 or attempts > 120,
    do: {trace, attempts}

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
      {%{violations: [found | _]}, _} ->
        found.property == violation.property and found.resource == violation.resource and
          found.verb == violation.verb

      _ ->
        false
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
          "evidence" => Enum.map(found, &to_json/1)
        }
      end

    passed = Enum.count(criteria, &(&1["status"] == "pass"))

    %{
      "subject" => subject,
      "outcome" =>
        if(passed == length(criteria) and report.moves > 0,
          do: "pass",
          else: if(report.moves == 0, do: "inconclusive", else: "fail")
        ),
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

    Enum.join(
      [head] ++
        if(violations == [], do: ["✓ no property broken"], else: violations) ++
        never ++ notes(report),
      "\n"
    )
  end

  # Offered, then refused by a domain rule or an input: not a broken
  # promise by itself, but what to look at when a verb is never reached;
  # then what the run could not use.
  defp notes(report) do
    refused =
      for {{:refused, kind, verb, detail}, n} <- Enum.sort(report.inconclusive),
          kind in [:domain, :invalid],
          do: "· #{verb} offered, refused #{n}× (#{kind}): #{detail}"

    unexplored =
      for {resource, reason} <- Enum.sort(report.unexplored),
          do: "· #{inspect(resource)} not explored: #{reason}"

    refused ++
      unexplored ++ for({what, n} <- Enum.sort(report.skipped), do: "· skipped #{n}×: #{what}")
  end

  @doc false
  def describe_move(%{kind: :clock, by: {n, unit}}),
    do: "clock +#{n}#{String.first(to_string(unit))}"

  def describe_move(%{kind: :probe} = move),
    do: "#{move.actor} tries #{type(move.ref)}.#{move.verb}"

  def describe_move(%{kind: :start} = move),
    do: "#{move.actor}.#{Mana.Entity.type(move.resource)}.#{move.verb}"

  def describe_move(%{kind: :verb} = move),
    do: "#{move.actor}.#{type(move.ref)}.#{move.verb}#{if move[:then_inverse], do: " (and back)"}"

  defp type({resource, index}), do: "#{Mana.Entity.type(resource)}##{index}"

  @doc """
  Writes `violation`'s trace as JSON to `dir/<name>.json` (by default named
  after the property, the record type and the verb); answers the path.
  """
  def save(%Violation{} = violation, dir, name \\ nil) do
    File.mkdir_p!(dir)

    name =
      name ||
        "#{violation.property}-#{Mana.Entity.type(violation.resource)}#{if violation.verb, do: "-#{violation.verb}"}"

    path = Path.join(dir, "#{name}.json")
    File.write!(path, Jason.encode!(to_json(violation), pretty: true) <> "\n")
    path
  end

  @doc "`violation` as `save/3` writes it: what broke, how, and the moves that break it."
  def to_json(%Violation{} = violation) do
    %{
      "property" => to_string(violation.property),
      "resource" => inspect(violation.resource),
      "verb" => violation.verb && to_string(violation.verb),
      "actor" => violation.actor && to_string(violation.actor),
      "detail" => violation.detail,
      "moves" => Enum.map(violation.trace, &move_json/1)
    }
    |> Map.merge(explored_json(violation.explored))
  end

  defp explored_json(nil), do: %{}

  defp explored_json(%{resources: resources, skip_rules: skip_rules}),
    do: %{
      "resources" => Enum.map(resources, &inspect/1),
      "skip_rules" => Enum.map(skip_rules, &to_string/1)
    }

  defp move_json(move) do
    move
    |> Map.new(fn
      {:ref, {resource, index}} ->
        {"ref", [inspect(resource), index]}

      {:resource, resource} ->
        {"resource", inspect(resource)}

      {:parent, nil} ->
        {"parent", nil}

      {:parent, {resource, index}} ->
        {"parent", [inspect(resource), index]}

      {:by, {n, unit}} ->
        {"by", [n, to_string(unit)]}

      {:params, params} ->
        {"params", Map.new(params, fn {k, v} -> {to_string(k), value_json(v)} end)}

      {key, value} when is_atom(value) ->
        {to_string(key), value && to_string(value)}

      {key, value} ->
        {to_string(key), value}
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
    moves =
      path
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("moves")
      |> Enum.map(&move_from_json/1)

    ctx = context(domains, actors: actors, reset: fn _ -> :ok end, properties: [])

    with_quiet_deadlines(fn ->
      state = %{new_state(ctx, 0) | actors: actors}

      state = Enum.reduce(moves, state, &rebuild_move(ctx, &1, &2))

      for {resource, ids} <- state.refs,
          {_id, index} <- Enum.with_index(ids),
          record = record(state, {resource, index}),
          into: %{},
          do: {{resource, index}, record}
    end)
  end

  @doc """
  Replays a saved trace (`save/3`'s file, or its decoded JSON) from a fresh
  store and checks only the property it broke, over the resources and rules
  the exploration checked: `{:failed, violation}` while the bug is there,
  `:passed` once it is fixed. A move the code no longer allows is attempted
  and goes on, as in any replay; a trace naming a resource, verb, actor or
  rule the app no longer has raises, so a stale trace is never a pass.
  Options as `run/2` (`setup` or `actors`, `reset`).
  """
  def check(trace, domains, opts \\ [])

  def check(path, domains, opts) when is_binary(path),
    do: path |> File.read!() |> Jason.decode!() |> check(domains, opts)

  def check(%{"property" => property, "moves" => moves} = trace, domains, opts)
      when is_list(moves) do
    property = String.to_existing_atom(property)

    unless property in @properties,
      do: raise(ArgumentError, "#{property} is not a property Mana.Explore checks")

    opts =
      opts
      |> Keyword.put(:properties, [property])
      |> put_new_some(:resources, trace["resources"] && Enum.map(trace["resources"], &module/1))
      |> put_new_some(
        :skip_rules,
        trace["skip_rules"] && Enum.map(trace["skip_rules"], &String.to_existing_atom/1)
      )

    case replay(domains, Enum.map(moves, &move_from_json/1), opts) do
      nil -> :passed
      violation -> {:failed, violation}
    end
  end

  defp put_new_some(opts, _key, nil), do: opts
  defp put_new_some(opts, key, value), do: Keyword.put_new(opts, key, value)

  defp rebuild_move(ctx, move, state) do
    state = %{state | trace: state.trace ++ [move]}

    state =
      case move do
        %{kind: :clock} -> advance(ctx, state, move.by)
        %{kind: :probe} -> state
        %{kind: :start} -> start(ctx, state, move)
        %{kind: :verb} -> verb_move(ctx, state, move)
      end

    discover(state, ctx)
  end

  defp move_from_json(json) do
    kind = String.to_existing_atom(json["kind"])

    base = %{kind: kind}

    base
    |> put_some(:actor, json["actor"] && String.to_existing_atom(json["actor"]))
    |> put_some(:verb, json["verb"] && String.to_existing_atom(json["verb"]))
    |> put_some(:ref, ref_from_json(json["ref"]))
    |> put_some(:resource, json["resource"] && module(json["resource"]))
    |> Map.put(:parent, ref_from_json(json["parent"]))
    |> put_some(
      :by,
      json["by"] && {hd(json["by"]), String.to_existing_atom(List.last(json["by"]))}
    )
    |> put_some(:then_inverse, json["then_inverse"])
    |> Map.put(
      :params,
      Map.new(json["params"] || %{}, fn {k, v} ->
        {String.to_existing_atom(k), param_from_json(v)}
      end)
    )
  end

  defp put_some(map, _key, nil), do: map
  defp put_some(map, key, value), do: Map.put(map, key, value)

  defp ref_from_json([resource, index]), do: {module(resource), index}
  defp ref_from_json(_), do: nil

  defp param_from_json(%{"ref" => [resource, index]}), do: {:ref, module(resource), index}
  defp param_from_json(%{"actor" => name}), do: {:actor, String.to_existing_atom(name)}
  defp param_from_json(value), do: value

  defp module(name),
    do: name |> String.trim_leading("Elixir.") |> String.split(".") |> Module.safe_concat()
end
