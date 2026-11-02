defmodule Moments.Recipe do
  @moduledoc """
  A backend recipe written next to the app it prepares, instead of in the engine.

  `prepare/1` puts the situation in place through the app's own Ash actions and
  returns the launch map the engine keeps privately: `route`, the `account` the
  Flutter app signs in with, `inputs` resolved by `fill` steps and, for a run
  that needs settings of its own, `knobScope` (`Mana.Knobs.scoped/2`), which
  the app then sends with every request. `observe/2` reads the persisted
  situation, inside that scope, and returns the projection that
  `backend_equals` checks compare. Neither may run outside development.

  A recipe declared with `data_scope: true` prepares in a database of its
  own (`Mana.Snapshot`, cloned from the migrated base) and returns
  `dataScope` in its launch; the app sends it as `x-mana-data-scope`
  (`Mana.Snapshot.Plug`) and `observe/2` runs there too, so suite workers
  never share rows. It needs `repo:` on `Moments.Recipes` and
  `config :mana_core, data_scopes: true`; the recipe seeds what it needs,
  since the shared base recipe ran on the shared database.
  """
  @callback prepare(context :: map) :: {:ok, map} | {:error, term}
  @callback observe(launch :: map, projection :: map) :: {:ok, map} | {:error, term}
end

defmodule Moments.Recipes do
  @moduledoc """
  Development-only Plug that serves app recipes to the Moments engine:

      forward "/__moments", Moments.Recipes,
        token: {MyApp, :moments_token, []},
        recipes: %{"partner-sign-up" => MyApp.Moments.SignUp},
        repo: MyApp.Repo,                    # for recipes with data_scope: true
                                             # ({MyApp.Repo, open_opts} passes Mana.Snapshot.open/3 options)
        history: [MyApp.History.Entry],      # Mana.History logs `project` reads
        explore: [domains: [MyApp.Bookings], setup: {MyApp.Explore, :actors, []}]

  Every call needs the sandbox's bearer token (at least 32 bytes, compared in
  constant time). Mount it only when the app is built for development.

  Besides `prepare` and `observe`, a prepared launch that carries a
  `dataScope` (a `data_scope: true` recipe) can be:

  - `fork`ed (`{"launch", "n"}`, 1–16): the scope is captured
    (`Mana.Snapshot.capture/3`) and cloned `n` times; each launch answered
    names its own scope, so the copies never see each other's writes. A
    launch with a `knobScope` is refused: knob values live outside the
    database and would be shared.
  - `project`ed (`{"launch"}`): the scope's row count per table, the entries
    of every `history:` log in the order they happened (subject, action,
    verb, actor kind, outcome, the changed fields before and after), and
    the recipe's `digest`, the MD5 of its compiled module (a set's, for a
    `Moments.RecipeSet` recipe), so a comparison across versions can tell a
    redefined recipe from changed behaviour. Values are as stored:
    normalizing ids and times is the runner's.

  `POST /_explorations/replay` (`{"trace"}`, a `Mana.Explore.save/2` file's
  contents) rebuilds an exploration in a scope of its own: `explore:` names
  the domains and the `setup` that creates its actors there
  (`Mana.Explore.replay_file/3`); it answers `{"dataScope"}`, a launch that
  `/_explorations/fork` and `/_explorations/project` take (with no recipe
  digest).
  """
  import Plug.Conn
  require Logger
  alias Mana.Snapshot
  alias Moments.RecipeSet

  # mana_core is optional: scoped operations check for Mana.Snapshot and
  # Mana.Explore at runtime.
  @compile {:no_warn_undefined, [Mana.Snapshot, Mana.Explore]}

  @max_forks 16

  def init(options), do: Map.new(options)

  def call(%{method: "POST", path_info: ["_explorations", operation]} = conn, options)
      when operation in ["replay", "fork", "project"] do
    if authorized?(conn, options.token) do
      result = explorations(operation, conn.body_params, options)
      respond(conn, "_explorations", operation, result)
    else
      reply(conn, 404, %{error: "not_found"})
    end
  end

  def call(%{method: "POST", path_info: [name, operation]} = conn, options)
      when operation in ["prepare", "observe", "fork", "project"] do
    with {:ok, module} <- Map.fetch(options.recipes, name),
         true <- authorized?(conn, options.token) do
      result = run(module, operation, conn.body_params, repo(Map.get(options, :repo)), options)
      respond(conn, name, operation, result)
    else
      _ -> reply(conn, 404, %{error: "not_found"})
    end
  end

  def call(conn, _options), do: reply(conn, 404, %{error: "not_found"})

  defp explorations("replay", params, options), do: replay(params, options)

  defp explorations(operation, params, options),
    do: run(nil, operation, params, repo(Map.get(options, :repo)), options)

  defp repo({repo, opts}), do: {repo, opts}
  defp repo(repo), do: {repo, []}

  defp run(_module, "fork", params, {repo, _open_opts}, _options) do
    launch = params["launch"]

    with {:ok, scope} <- launch_scope(launch, repo),
         :ok <- forkable(launch, params["n"]) do
      {:ok, %{"launches" => fork(repo, scope, params["n"], launch)}}
    end
  end

  defp run(module, "project", params, {repo, _open_opts}, options) do
    with {:ok, scope} <- launch_scope(params["launch"], repo) do
      Snapshot.with_scope(repo, scope, fn ->
        {:ok,
         %{
           "recipe" => digest(module),
           "tables" => counts(repo),
           "history" => Enum.flat_map(Map.get(options, :history, []), &entries/1)
         }}
      end)
    end
  end

  defp run(module, operation, params, repo, _options), do: run(module, operation, params, repo)

  defp run({set, key}, "prepare", params, {repo, open_opts}) do
    in_data_scope(set.__recipe__(:data_scope?, key), repo, open_opts, fn ->
      set.__recipe__(:prepare, key, params["context"] || %{})
    end)
  end

  defp run({set, key}, "observe", params, {repo, _open_opts}) do
    scoped(params["launch"], repo, fn ->
      set.__recipe__(:observe, key, params["launch"] || %{}, params["projection"] || %{})
    end)
  end

  defp run(module, "prepare", params, _repo), do: module.prepare(params["context"] || %{})

  defp run(module, "observe", params, {repo, _open_opts}) do
    scoped(params["launch"], repo, fn ->
      module.observe(params["launch"] || %{}, params["projection"] || %{})
    end)
  end

  defp launch_scope(%{"dataScope" => scope}, repo) when is_binary(scope) do
    if scopes_enabled?(repo) and scope in Snapshot.scopes(repo),
      do: {:ok, scope},
      else: {:error, :unknown_data_scope}
  end

  defp launch_scope(_launch, _repo), do: {:error, :no_data_scope}

  defp forkable(%{"knobScope" => _}, _n), do: {:error, :knob_scope_not_forkable}
  defp forkable(_launch, n) when is_integer(n) and n in 1..@max_forks, do: :ok
  defp forkable(_launch, _n), do: {:error, :invalid_fork_count}

  defp fork(repo, scope, n, launch) do
    snapshot = "fork_" <> scope
    Snapshot.capture(repo, scope, snapshot)

    try do
      for id <- Snapshot.fork(repo, snapshot, n) do
        forget_old_scopes(repo, id)
        Map.put(launch, "dataScope", id)
      end
    after
      Snapshot.drop_snapshot(repo, snapshot)
    end
  end

  # Conservative on purpose: any change to the module that holds the recipe
  # (its helpers, the set's other recipes) reads as a redefinition, so a
  # changed recipe is never taken for changed behaviour.
  defp digest(nil), do: nil
  defp digest({set, _key}), do: digest(set)
  defp digest(module), do: module.module_info(:md5) |> Base.encode16(case: :lower)

  # Catalog reads in the scope's own database, outside any Ash resource: what
  # a whole-situation projection counts is every table, not only modelled ones.
  defp counts(repo) do
    %{rows: tables} =
      repo.query!(
        "SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> 'schema_migrations' ORDER BY tablename",
        [],
        log: false
      )

    Map.new(tables, fn [table] ->
      %{rows: [[count]]} = repo.query!(~s[SELECT count(*) FROM "#{table}"], [], log: false)
      {table, count}
    end)
  end

  defp entries(log) do
    log
    |> Ash.Query.sort(at: :asc, id: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(
      &%{
        "log" => inspect(log),
        "subject" => "#{&1.subject_type}:#{&1.subject_id}",
        "action" => &1.action,
        "verb" => &1.verb,
        "actorKind" => to_string(&1.actor_kind),
        "outcome" => to_string(&1.outcome),
        "before" => &1.before,
        "after" => &1.after
      }
    )
  end

  defp replay(%{"trace" => %{"moves" => moves} = trace}, options) when is_list(moves) do
    {repo, open_opts} = repo(Map.get(options, :repo))
    explore = Map.get(options, :explore)

    unless scopes_enabled?(repo) and Code.ensure_loaded?(Mana.Explore) and explore,
      do:
        raise(
          ArgumentError,
          "replaying an exploration needs repo:, explore: [domains:, setup:] and config :mana_core, data_scopes: true"
        )

    scope = Snapshot.open(repo, :base, open_opts)
    forget_old_scopes(repo, scope)
    path = Path.join(System.tmp_dir!(), "moments-exploration-#{scope}.json")
    File.write!(path, Jason.encode!(trace))

    try do
      Snapshot.with_scope(repo, scope, fn ->
        {module, function, args} = Keyword.fetch!(explore, :setup)

        refs =
          Mana.Explore.replay_file(
            path,
            Keyword.fetch!(explore, :domains),
            apply(module, function, args)
          )

        {:ok, %{"dataScope" => scope, "records" => map_size(refs)}}
      end)
    rescue
      error ->
        Snapshot.drop(repo, scope)
        reraise error, __STACKTRACE__
    after
      File.rm(path)
    end
  end

  defp replay(_params, _options), do: {:error, :invalid_exploration}

  defp scopes_enabled?(repo),
    do:
      not is_nil(repo) and Code.ensure_loaded?(Mana.Snapshot) and
        Application.get_env(:mana_core, :data_scopes, false) == true

  defp respond(conn, _name, _operation, {:ok, value}) when is_map(value),
    do: reply(conn, 200, value)

  defp respond(conn, name, operation, other) do
    Logger.warning("Moment recipe #{name} #{operation} failed: #{inspect(other)}")
    reply(conn, 422, %{error: "recipe_failed"})
  end

  defp scoped(launch, repo, observe) do
    data_scoped(launch, repo, fn -> knob_scoped(launch, observe) end)
  end

  # Mana.Knobs reads its scope from the process.
  defp knob_scoped(%{"knobScope" => scope}, observe) when is_binary(scope) do
    Process.put(:mana_knob_scope, scope)

    try do
      observe.()
    after
      Process.delete(:mana_knob_scope)
    end
  end

  defp knob_scoped(_launch, observe), do: observe.()

  defp data_scoped(%{"dataScope" => scope}, repo, observe)
       when is_binary(scope) and not is_nil(repo),
       do: Snapshot.with_scope(repo, scope, observe)

  defp data_scoped(_launch, _repo, observe), do: observe.()

  @kept_scopes 16

  defp in_data_scope(false, _repo, _opts, prepare), do: prepare.()

  defp in_data_scope(true, repo, opts, prepare) do
    unless scopes_enabled?(repo),
      do:
        raise(
          ArgumentError,
          "a data_scope recipe needs repo: on Moments.Recipes and config :mana_core, data_scopes: true"
        )

    scope = Snapshot.open(repo, :base, opts)
    forget_old_scopes(repo, scope)

    case RecipeSet.wrap(Snapshot.with_scope(repo, scope, prepare)) do
      {:ok, launch} -> {:ok, Map.put(launch, "dataScope", scope)}
      error -> Snapshot.drop(repo, scope) && error
    end
  end

  # Scopes outlive their Moment (it may be opened again); the oldest go once
  # more than a full suite's worth are open.
  defp forget_old_scopes(repo, scope) do
    key = {__MODULE__, :scopes, repo}
    {kept, old} = Enum.split([scope | :persistent_term.get(key, [])], @kept_scopes)
    :persistent_term.put(key, kept)
    Enum.each(old, &Snapshot.drop(repo, &1))
  end

  defp authorized?(conn, {module, function, args}) do
    token = apply(module, function, args)

    with true <- is_binary(token) and byte_size(token) >= 32,
         ["Bearer " <> given] <- get_req_header(conn, "authorization") do
      Plug.Crypto.secure_compare(given, token)
    else
      _ -> false
    end
  end

  defp reply(conn, status, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
    |> halt()
  end
end

defmodule Moments.RecipeSet do
  @moduledoc """
  Recipes declared together, sharing their helpers and how they observe:

      defmodule MyApp.Moments.Operators do
        use Moments.RecipeSet, observe: :observe

        recipe :operator_signed_in, "An operator signed in on the points." do
          launch("/points", operator())
        end

        def observe(launch, projection), do: ...
      end

  A recipe's body returns the launch map (or `{:ok, map}` / `{:error, term}`)
  and may read `context`; `observe:` names this module's `observe/2`, and a
  recipe can pass its own; `data_scope: true` prepares it in a database of
  its own (see `Moments.Recipes`). `__recipes__/0` maps each recipe's dashed name
  (`operator-signed-in`, what a Moment's `backend` names) for `Moments.Recipes`.
  """
  defmacro __using__(opts) do
    quote do
      import Moments.RecipeSet, only: [recipe: 3, recipe: 4]
      Module.register_attribute(__MODULE__, :moments_recipes, accumulate: true)
      @moments_observe unquote(Keyword.get(opts, :observe))
      @before_compile Moments.RecipeSet
    end
  end

  defmacro recipe(name, description, opts \\ [], do: block) do
    quote do
      @moments_recipes {unquote(name), unquote(description), unquote(Keyword.get(opts, :observe)),
                        unquote(Macro.escape(block)),
                        unquote(Keyword.get(opts, :data_scope, false))}
    end
  end

  defmacro __before_compile__(env) do
    recipes = env.module |> Module.get_attribute(:moments_recipes) |> Enum.reverse()
    default = Module.get_attribute(env.module, :moments_observe)

    prepares = Enum.map(recipes, &prepare_clause/1)
    observes = Enum.map(recipes, &observe_clause(&1, default))
    scoped = Enum.map(recipes, &data_scope_clause/1)

    quote do
      unquote_splicing(prepares)
      unquote_splicing(observes)
      unquote_splicing(scoped)

      def __recipes__,
        do:
          Map.new(
            unquote(Enum.map(recipes, &elem(&1, 0))),
            &{&1 |> to_string() |> String.replace("_", "-"), {__MODULE__, &1}}
          )

      def __recipe_descriptions__,
        do:
          Map.new(
            unquote(
              Macro.escape(
                Enum.map(recipes, fn {name, description, _, _, _} -> {name, description} end)
              )
            )
          )
    end
  end

  defp prepare_clause({name, _, _, block, _}) do
    quote do
      def __recipe__(:prepare, unquote(name), var!(context)) do
        _ = var!(context)
        Moments.RecipeSet.wrap(unquote(block))
      end
    end
  end

  defp observe_clause({name, _, own, _, _}, default) do
    observe =
      own || default ||
        raise ArgumentError, "recipe #{name} needs `observe:` (on the set or the recipe)"

    quote do
      def __recipe__(:observe, unquote(name), launch, projection),
        do: unquote(observe)(launch, projection)
    end
  end

  defp data_scope_clause({name, _, _, _, data_scope}) do
    quote do
      def __recipe__(:data_scope?, unquote(name)), do: unquote(data_scope) == true
    end
  end

  @doc false
  def wrap({:ok, map} = result) when is_map(map), do: result
  def wrap({:error, _} = result), do: result
  def wrap(map) when is_map(map), do: {:ok, map}
end
