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
  """
  @callback prepare(context :: map) :: {:ok, map} | {:error, term}
  @callback observe(launch :: map, projection :: map) :: {:ok, map} | {:error, term}
end

defmodule Moments.Recipes do
  @moduledoc """
  Development-only Plug that serves app recipes to the Moments engine:

      forward "/__moments", Moments.Recipes,
        token: {MyApp, :moments_token, []},
        recipes: %{"partner-sign-up" => MyApp.Moments.SignUp}

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

      result =
        case {module, operation} do
          {{set, key}, "prepare"} -> set.__recipe__(:prepare, key, params["context"] || %{})
          {{set, key}, "observe"} -> scoped(params["launch"], fn -> set.__recipe__(:observe, key, params["launch"] || %{}, params["projection"] || %{}) end)
          {module, "prepare"} -> module.prepare(params["context"] || %{})
          {module, "observe"} -> scoped(params["launch"], fn -> module.observe(params["launch"] || %{}, params["projection"] || %{}) end)
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

  # Mana.Knobs reads its scope from the process.
  defp scoped(%{"knobScope" => scope}, observe) when is_binary(scope) do
    Process.put(:mana_knob_scope, scope)

    try do
      observe.()
    after
      Process.delete(:mana_knob_scope)
    end
  end

  defp scoped(_launch, observe), do: observe.()

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
  recipe can pass its own. `__recipes__/0` maps each recipe's dashed name
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
                        unquote(Macro.escape(block))}
    end
  end

  defmacro __before_compile__(env) do
    recipes = env.module |> Module.get_attribute(:moments_recipes) |> Enum.reverse()
    default = Module.get_attribute(env.module, :moments_observe)

    prepares =
      for {name, _, _, block} <- recipes do
        quote do
          def __recipe__(:prepare, unquote(name), var!(context)) do
            _ = var!(context)
            Moments.RecipeSet.wrap(unquote(block))
          end
        end
      end

    observes =
      for {name, _, own, _} <- recipes do
        observe = own || default || raise ArgumentError, "recipe #{name} needs `observe:` (on the set or the recipe)"

        quote do
          def __recipe__(:observe, unquote(name), launch, projection), do: unquote(observe)(launch, projection)
        end
      end

    quote do
      unquote_splicing(prepares)
      unquote_splicing(observes)

      def __recipes__,
        do: Map.new(unquote(Enum.map(recipes, &elem(&1, 0))), &{&1 |> to_string() |> String.replace("_", "-"), {__MODULE__, &1}})

      def __recipe_descriptions__, do: Map.new(unquote(Macro.escape(Enum.map(recipes, fn {name, description, _, _} -> {name, description} end))))
    end
  end

  @doc false
  def wrap({:ok, map} = result) when is_map(map), do: result
  def wrap({:error, _} = result), do: result
  def wrap(map) when is_map(map), do: {:ok, map}
end
