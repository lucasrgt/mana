# The runner reads screens with LazyHTML, which apps have in their tests only.
if Code.ensure_loaded?(LazyHTML) do
  defmodule ManaWeb.Moments do
    @moduledoc """
    Runs Moments on LiveView screens, headless, inside the app's `mix test`: the
    LiveView half of the Moments runner the Flutter adapter has in Dart.

    It reads the same manifest (`Moments.Manifest`), so a Moment is declared once
    in Ash and both runners judge it by the same rules: the recipe prepares the
    situation through the app's own actions, the screen is mounted as the
    launch's account, the steps run in order, each step's `until` criteria are
    observed after it, the final criteria at the end, and the report carries the
    AVP verdict both runners give (`ManaWeb.Moments.Verdict`).

        report =
          ManaWeb.Moments.run(manifest, "admin-sets-default-agency",
            endpoint: MyAppWeb.Endpoint,
            recipes: MyApp.Moments.Agencies.__recipes__(),
            sign_in: &MyAppWeb.MomentsTest.sign_in/2
          )

        report["verdict"]["outcome"] #=> "pass"

    `ManaWeb.Moments.Case` turns every Moment of a manifest into a test.

    ## What the LiveView screen reports

    - **Offered verbs.** `ManaWeb.Verbs.gate` marks its content with
      `data-mana-verb="type.verb:<id>"`, as `VerbGate` keys a Flutter control;
      `offered` and `not_offered` read those marks, and a `verb:` step clicks the
      `phx-click` inside the record's mark (`on:` names the input that holds its id).
    - **UI fields.** An element with `data-moment-field="<field>"` reports that
      declared field, its value in `data-moment-value` (or its text); `ui_equals`
      reads it.
    - **Keys.** A `tap:` step clicks the element with `data-moment-key="<key>"`.

    ## What runs on LiveView, and what does not yet

    `tap` and `verb` steps, and the `offered`, `not_offered`, `ui_equals` and
    `backend_equals` criteria run. `fill`, `submit`, `reveal`, `swipe`,
    `long_press` and `back` steps are reported unavailable, and so is
    `restored`: a LiveView keeps its state in its process, with nothing to
    restore. Unavailable evidence is never green: the verdict is then
    inconclusive. A Moment whose `platforms` leave out `web` is not applicable.

    `backend_equals` identifies the record by the launch's `inputs` under the
    check's `match` (then the Moment's projection), and compares the recipe's
    `observe/2` projection.
    """

    import Phoenix.ConnTest, only: [build_conn: 0, dispatch: 5]
    import Phoenix.LiveViewTest

    alias ManaWeb.Moments.Verdict

    @doc """
    Runs `name` from `manifest` (one app's `Moments.Manifest.build/2`, or the
    `moments` map of `build_many/2`'s) and answers its report.

    Options: `endpoint:` (required), `recipes:` (the recipe map that
    `Moments.Recipes` serves: dashed name to a `Moments.Recipe` module or a
    `{set, key}` of a `Moments.RecipeSet`), `sign_in:` (a function of the conn and
    the launch's `account`, called when there is one), `conn:` (a starting conn).
    """
    def run(manifest, name, opts) do
      moments = manifest["moments"] || manifest
      moment = Map.fetch!(moments, name)

      if web?(moment) do
        journey(moments, name, moment, opts)
      else
        report(
          name,
          "not-applicable",
          [],
          [],
          "The Moment exists only on #{Enum.join(moment["platforms"], ", ")}"
        )
      end
    end

    @doc "Whether `moment` exists on the web, where LiveView screens live."
    def web?(moment), do: "web" in (moment["platforms"] || ["web"])

    defp journey(moments, name, moment, opts) do
      endpoint = Keyword.fetch!(opts, :endpoint)

      with {:ok, launch} <- prepare(moments, moment, opts),
           {:ok, view} <- mount(endpoint, launch, opts) do
        walk(name, moment, launch, view, endpoint, opts)
      else
        {:error, reason} ->
          report(name, "failed", [], [], "The Moment did not open: #{inspect(reason)}")
      end
    end

    # A child Moment prepares on its parent's launch (`context["parent"]`), as the Dart runner does.
    defp prepare(moments, moment, opts) do
      context =
        case moment["from"] do
          nil ->
            {:ok, %{}}

          parent ->
            with {:ok, launch} <- prepare(moments, Map.fetch!(moments, parent), opts),
                 do: {:ok, %{"parent" => launch}}
        end

      with {:ok, context} <- context do
        case moment["backend"] do
          nil -> {:ok, %{"route" => moment["projection"]["route"]}}
          %{"recipe" => recipe} -> recipe(opts, recipe, :prepare, [context])
        end
      end
    end

    defp recipe(opts, name, operation, args) do
      case Map.fetch(Keyword.get(opts, :recipes, %{}), name) do
        {:ok, {set, key}} -> wrap(apply(set, :__recipe__, [operation, key | args]))
        {:ok, module} -> wrap(apply(module, operation, args))
        :error -> {:error, "no recipe #{name} in recipes:"}
      end
    end

    defp wrap({:ok, map}) when is_map(map), do: {:ok, map}
    defp wrap({:error, _reason} = error), do: error
    defp wrap(map) when is_map(map), do: {:ok, map}

    defp mount(endpoint, launch, opts) do
      conn = Keyword.get_lazy(opts, :conn, &build_conn/0)

      conn =
        case {launch["account"], opts[:sign_in]} do
          {nil, _sign_in} -> conn
          {account, sign_in} when is_function(sign_in, 2) -> sign_in.(conn, account)
          {_account, nil} -> raise ArgumentError, "the launch signs in an account: pass sign_in:"
        end

      route = launch["route"] || "/"

      case live(Plug.Conn.put_private(conn, :mana_moments_endpoint, endpoint), route) do
        {:ok, view, _html} -> {:ok, %{view: view, conn: conn}}
        {:error, reason} -> {:error, reason}
      end
    end

    defp walk(name, moment, launch, screen, endpoint, opts) do
      checks = moment["checks"] || []
      by_name = Map.new(checks, &{&1["name"], &1})
      observe = &evaluate(&1, &2, moment, launch, opts)

      {screen, steps, observed} =
        Enum.reduce_while(moment["steps"] || [], {screen, [], []}, fn step,
                                                                      {screen, steps, observed} ->
          case act(screen, step, launch, endpoint) do
            {:ok, screen} ->
              results = Enum.map(step["until"] || [], &observe.(by_name[&1], screen))

              {:cont,
               {screen, steps ++ [%{"name" => step["name"], "status" => "done"}],
                observed ++ results}}

            {:error, status, reason} ->
              receipt = %{"name" => step["name"], "status" => status, "reason" => reason}
              {:halt, {screen, steps ++ [receipt], observed}}
          end
        end)

      results =
        observed ++ for(check <- checks, check["scope"] != "step", do: observe.(check, screen))

      reason =
        Enum.find_value(steps, &(&1["status"] != "done" && "#{&1["name"]}: #{&1["reason"]}"))

      report(name, status(steps ++ Enum.reject(results, &is_nil/1)), results, steps, reason)
    end

    # Any failed step or criterion fails the Moment; otherwise any unavailable one leaves it unavailable.
    defp status(outcomes) do
      statuses = MapSet.new(outcomes, & &1["status"])

      cond do
        "failed" in statuses -> "failed"
        "unavailable" in statuses -> "unavailable"
        true -> "passed"
      end
    end

    defp act(screen, %{"kind" => "tap", "verb" => verb} = step, launch, endpoint) do
      mark =
        case step["inputRef"] do
          nil -> ~s([data-mana-verb^="#{verb}"])
          ref -> ~s([data-mana-verb="#{verb}:#{input(launch, ref)}"])
        end

      click(screen, "#{mark} [phx-click]", "no control offers #{verb}", endpoint)
    end

    defp act(screen, %{"kind" => "tap", "target" => key}, _launch, endpoint),
      do: click(screen, ~s([data-moment-key="#{key}"]), "nothing has the key #{key}", endpoint)

    defp act(_screen, %{"kind" => kind}, _launch, _endpoint),
      do: {:error, "unavailable", "#{kind} steps do not run on LiveView yet"}

    defp click(%{view: view} = screen, selector, missing, endpoint) do
      if has_element?(view, selector) do
        case view |> element(first(view, selector)) |> render_click() do
          {:error, {kind, %{to: to}}} when kind in [:redirect, :live_redirect] ->
            remount(screen, to, endpoint)

          _html ->
            {:ok, screen}
        end
      else
        {:error, "failed", missing}
      end
    end

    # LiveViewTest clicks exactly one element: a selector that finds several narrows to the first one's id.
    defp first(view, selector) do
      case view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(selector)
           |> Enum.to_list() do
        [_one] ->
          selector

        [node | _] ->
          case LazyHTML.attribute(node, "id") do
            [id] when id != "" -> "#" <> id
            _ -> raise ArgumentError, "#{selector} finds several controls; give them ids"
          end
      end
    end

    defp remount(%{conn: conn} = screen, to, endpoint) do
      case live(Plug.Conn.put_private(conn, :mana_moments_endpoint, endpoint), to) do
        {:ok, view, _html} ->
          {:ok, %{screen | view: view}}

        {:error, reason} ->
          {:error, "failed", "the screen went to #{to} and did not open: #{inspect(reason)}"}
      end
    end

    # `live/2` requests the page with `get/2`, which a test module takes from its `@endpoint`; here the
    # endpoint is an option, carried on the conn.
    defp get(conn, path), do: dispatch(conn, conn.private.mana_moments_endpoint, :get, path, nil)

    defp evaluate(nil, _screen, _moment, _launch, _opts), do: nil

    defp evaluate(%{"kind" => kind} = check, screen, _moment, _launch, _opts)
         when kind in ["offered", "not_offered"] do
      verb = check["verb"]
      wanted? = kind == "offered"

      controls =
        for id <- offered(screen), id == verb or String.starts_with?(id, verb <> ":"), do: id

      %{
        "name" => check["name"],
        "status" => if(controls != [] == wanted?, do: "passed", else: "failed"),
        "verb" => verb,
        "expected" => if(wanted?, do: "offered", else: "not-offered"),
        "observed" => Enum.take(controls, 16),
        "meaning" =>
          "Verbs the mounted controls (ManaWeb.Verbs.gate) offered on the LiveView screen; not proof the server would accept them."
      }
    end

    defp evaluate(
           %{"kind" => "ui_equals", "field" => field} = check,
           screen,
           _moment,
           _launch,
           _opts
         ) do
      case Map.fetch(fields(screen), field) do
        {:ok, actual} ->
          %{
            "name" => check["name"],
            "status" => if(actual == to_string(check["equals"]), do: "passed", else: "failed"),
            "field" => field,
            "expected" => check["equals"],
            "observed" => actual,
            "meaning" =>
              "Value the LiveView screen reported; not proof of a gesture or backend persistence."
          }

        :error ->
          unavailable(check, "Declared UI observation is unavailable or not a scalar")
      end
    end

    defp evaluate(%{"kind" => "backend_equals"} = check, _screen, moment, launch, opts) do
      %{"field" => field, "match" => match} = check
      identity = input(launch, match) || moment["projection"][match]

      with %{"recipe" => recipe} <- moment["backend"],
           {:ok, projection} <- recipe(opts, recipe, :observe, [launch, %{match => identity}]),
           true <- Map.has_key?(projection, field) || :missing,
           true <-
             (is_binary(identity) and identity != "" and projection[match] == identity) ||
               :identity do
        actual = projection[field]

        if scalar?(actual) do
          %{
            "name" => check["name"],
            "status" => if(actual == check["equals"], do: "passed", else: "failed"),
            "expected" => check["equals"],
            "observed" => actual,
            "field" => field,
            "identityMatched" => true,
            "source" => recipe
          }
        else
          unavailable(check, "Backend criterion is not a scalar")
        end
      else
        :identity -> unavailable(check, "Backend observation does not identify the UI entity")
        _ -> unavailable(check, "Backend observation unavailable or missing declared field")
      end
    end

    defp evaluate(%{"kind" => "restored"} = check, _screen, _moment, _launch, _opts),
      do:
        unavailable(
          check,
          "A LiveView keeps its state in its process; there is nothing to restore"
        )

    defp evaluate(check, _screen, _moment, _launch, _opts),
      do: unavailable(check, "#{check["kind"]} criteria do not run on LiveView")

    defp unavailable(check, reason),
      do: %{"name" => check["name"], "status" => "unavailable", "reason" => reason}

    @doc "The verbs the screen's controls offer, as `type.verb:<id>`."
    def offered(%{view: view}),
      do: view |> render() |> attributes("[data-mana-verb]", "data-mana-verb")

    defp fields(%{view: view}) do
      html = view |> render() |> LazyHTML.from_fragment()

      for node <- LazyHTML.query(html, "[data-moment-field]"), into: %{} do
        [field] = LazyHTML.attribute(node, "data-moment-field")

        value =
          case LazyHTML.attribute(node, "data-moment-value") do
            [value] -> value
            [] -> node |> LazyHTML.text() |> String.trim()
          end

        {field, value}
      end
    end

    defp attributes(html, selector, name),
      do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)

    defp input(launch, ref), do: get_in(launch, ["inputs", ref])

    defp scalar?(value), do: is_binary(value) or is_number(value) or is_boolean(value)

    defp report(name, status, checks, steps, reason) do
      checks = Enum.reject(checks, &is_nil/1)

      %{
        "moment" => name,
        "runner" => "mana_web",
        "status" => status,
        "checks" => checks,
        "steps" => steps,
        "verdict" => Verdict.avp(name, status, checks, reason)
      }
    end
  end
end
