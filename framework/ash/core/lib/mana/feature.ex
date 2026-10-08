defmodule Mana.Feature do
  @moduledoc """
  Production health by `feature:<name>`: every JSON:API request is labelled
  with the feature of the operation it reaches (the feature of the verb its
  action performs, or of its resource's verbs for a read), and each feature
  keeps its recent requests, failures and latency, so errors and slowness
  read as "checkout is failing", not as an endpoint.

      plug Mana.Feature.Plug, otp_app: :my_app, prefix: "/api"

  Start `Mana.Feature` in the supervision tree; `report/1` answers the last
  `minutes` (60) per feature: requests, server errors, refusals and the 95th
  percentile in milliseconds.
  """
  use GenServer

  @table __MODULE__
  @kept 2_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :bag, write_concurrency: true])
    {:ok, nil}
  end

  @doc false
  def record(feature, status, duration_us) do
    if :ets.whereis(@table) != :undefined do
      :ets.insert(@table, {feature, System.system_time(:millisecond), status, duration_us})
      if :rand.uniform(200) == 1, do: trim(feature)
    end

    :ok
  end

  defp trim(feature) do
    entries = :ets.lookup(@table, feature)

    if length(entries) > @kept do
      entries |> Enum.sort_by(&elem(&1, 1)) |> Enum.take(length(entries) - @kept) |> Enum.each(&:ets.delete_object(@table, &1))
    end
  end

  @doc "Per feature over the last `minutes`: requests, errors (5xx), refused (4xx) and p95 latency in ms, worst first."
  def report(minutes \\ 60) do
    since = System.system_time(:millisecond) - minutes * 60_000

    if :ets.whereis(@table) == :undefined do
      []
    else
      @table
      |> :ets.tab2list()
      |> Enum.filter(&(elem(&1, 1) >= since))
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.map(fn {feature, entries} ->
        durations = entries |> Enum.map(&elem(&1, 3)) |> Enum.sort()

        %{
          feature: feature,
          requests: length(entries),
          errors: Enum.count(entries, &(elem(&1, 2) >= 500)),
          refused: Enum.count(entries, &(elem(&1, 2) in 400..499)),
          p95_ms: Float.round(Enum.at(durations, max(ceil(length(durations) * 0.95) - 1, 0)) / 1000, 1)
        }
      end)
      |> Enum.sort_by(&{-&1.errors, -&1.p95_ms})
    end
  end

  @doc "The routes of `domains` under `prefix`, each with the feature it belongs to."
  def routes(domains, prefix) do
    for domain <- domains,
        route <- AshJsonApi.Domain.Info.routes(domain),
        feature = feature(route.resource, route.action),
        feature != nil do
      {String.upcase(to_string(route.method)), segments(prefix <> route.route), feature}
    end
  end

  @doc "The feature a request to `method` `path` belongs to, from `routes/2`."
  def of(routes, method, path) do
    got = path |> String.split("/", trim: true)

    Enum.find_value(routes, fn {route_method, want, feature} ->
      if route_method == method and matches?(want, got), do: feature
    end)
  end

  defp feature(resource, action) do
    verbs = if Mana.Verbs in Spark.extensions(resource), do: Mana.Verbs.declared(resource), else: []

    Enum.find_value(verbs, &(Mana.Verbs.action(&1) == action && &1.feature)) ||
      Enum.find_value(verbs, & &1.feature)
  end

  defp segments(path), do: String.split(path, "/", trim: true)

  defp matches?(want, got) when length(want) == length(got),
    do: Enum.zip(want, got) |> Enum.all?(fn {w, g} -> String.starts_with?(w, ":") or w == g end)

  defp matches?(_want, _got), do: false
end

defmodule Mana.Feature.Plug do
  @moduledoc "Labels each request with its feature (`Mana.Feature`) and records its outcome and duration."
  @behaviour Plug

  @impl true
  def init(opts), do: {Keyword.fetch!(opts, :otp_app), Keyword.get(opts, :prefix, "/api")}

  @impl true
  def call(conn, {otp_app, prefix}) do
    routes = routes(otp_app, prefix)

    case Mana.Feature.of(routes, conn.method, conn.request_path) do
      nil ->
        conn

      feature ->
        started = System.monotonic_time(:microsecond)

        conn
        |> Plug.Conn.put_private(:mana_feature, feature)
        |> Plug.Conn.register_before_send(fn conn ->
          Mana.Feature.record(feature, conn.status || 200, System.monotonic_time(:microsecond) - started)
          conn
        end)
    end
  end

  defp routes(otp_app, prefix) do
    key = {Mana.Feature, otp_app, prefix}

    case :persistent_term.get(key, nil) do
      nil ->
        routes = Mana.Feature.routes(Application.fetch_env!(otp_app, :ash_domains), prefix)
        :persistent_term.put(key, routes)
        routes

      routes ->
        routes
    end
  end
end
