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
        repo: MyApp.Repo                     # for recipes with data_scope: true
                                             # ({MyApp.Repo, open_opts} passes Mana.Snapshot.open/3 options)

  Every call needs the sandbox's bearer token (at least 32 bytes, compared in
  constant time). Mount it only when the app is built for development.
  """
  import Plug.Conn
  require Logger

  def init(options), do: Map.new(options)

  def call(%{method: "POST", path_info: [name, operation]} = conn, options)
      when operation in ["prepare", "observe"] do
    with {:ok, module} <- Map.fetch(options.recipes, name),
         true <- authorized?(conn, options.token) do
      params = conn.body_params

      {repo, open_opts} =
        case Map.get(options, :repo) do
          {repo, opts} -> {repo, opts}
          repo -> {repo, []}
        end

      result =
        case {module, operation} do
          {{set, key}, "prepare"} ->
            in_data_scope(set.__recipe__(:data_scope?, key), repo, open_opts, fn ->
              set.__recipe__(:prepare, key, params["context"] || %{})
            end)

          {{set, key}, "observe"} ->
            scoped(params["launch"], repo, fn ->
              set.__recipe__(:observe, key, params["launch"] || %{}, params["projection"] || %{})
            end)

          {module, "prepare"} ->
            module.prepare(params["context"] || %{})

          {module, "observe"} ->
            scoped(params["launch"], repo, fn ->
              module.observe(params["launch"] || %{}, params["projection"] || %{})
            end)
        end

      case result do
        {:ok, value} when is_map(value) ->
          reply(conn, 200, value)

        other ->
          Logger.warning("Moment recipe #{name} #{operation} failed: #{inspect(other)}")
          reply(conn, 422, %{error: "recipe_failed"})
      end
    else
      _ -> reply(conn, 404, %{error: "not_found"})
    end
  end

  def call(conn, _options), do: reply(conn, 404, %{error: "not_found"})

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
       do: apply(Mana.Snapshot, :with_scope, [repo, scope, observe])

  defp data_scoped(_launch, _repo, observe), do: observe.()

  @kept_scopes 16

  defp in_data_scope(false, _repo, _opts, prepare), do: prepare.()

  defp in_data_scope(true, repo, opts, prepare) do
    unless (repo && Code.ensure_loaded?(Mana.Snapshot)) and
             Application.get_env(:mana_core, :data_scopes, false) == true,
           do:
             raise(
               ArgumentError,
               "a data_scope recipe needs repo: on Moments.Recipes and config :mana_core, data_scopes: true"
             )

    scope = apply(Mana.Snapshot, :open, [repo, :base, opts])
    forget_old_scopes(repo, scope)

    case apply(Mana.Snapshot, :with_scope, [repo, scope, prepare]) |> Moments.RecipeSet.wrap() do
      {:ok, launch} -> {:ok, Map.put(launch, "dataScope", scope)}
      error -> apply(Mana.Snapshot, :drop, [repo, scope]) && error
    end
  end

  # Scopes outlive their Moment (it may be opened again); the oldest go once
  # more than a full suite's worth are open.
  defp forget_old_scopes(repo, scope) do
    key = {__MODULE__, :scopes, repo}
    {kept, old} = Enum.split([scope | :persistent_term.get(key, [])], @kept_scopes)
    :persistent_term.put(key, kept)
    Enum.each(old, &apply(Mana.Snapshot, :drop, [repo, &1]))
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

    prepares =
      for {name, _, _, block, _} <- recipes do
        quote do
          def __recipe__(:prepare, unquote(name), var!(context)) do
            _ = var!(context)
            Moments.RecipeSet.wrap(unquote(block))
          end
        end
      end

    observes =
      for {name, _, own, _, _} <- recipes do
        observe =
          own || default ||
            raise ArgumentError, "recipe #{name} needs `observe:` (on the set or the recipe)"

        quote do
          def __recipe__(:observe, unquote(name), launch, projection),
            do: unquote(observe)(launch, projection)
        end
      end

    scoped =
      for {name, _, _, _, data_scope} <- recipes do
        quote do
          def __recipe__(:data_scope?, unquote(name)), do: unquote(data_scope) == true
        end
      end

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

  @doc false
  def wrap({:ok, map} = result) when is_map(map), do: result
  def wrap({:error, _} = result), do: result
  def wrap(map) when is_map(map), do: {:ok, map}
end
