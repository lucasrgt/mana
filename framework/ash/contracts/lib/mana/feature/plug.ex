defmodule Mana.Feature.Plug do
  @moduledoc "Labels each JSON:API request with its feature (`Mana.Feature`) and records its outcome and duration."
  @behaviour Plug

  alias AshJsonApi.Domain.Info

  @impl true
  def init(opts), do: {Keyword.fetch!(opts, :otp_app), Keyword.get(opts, :prefix, "/api")}

  @impl true
  def call(conn, {otp_app, prefix}) do
    routes = cached_routes(otp_app, prefix)

    case of(routes, conn.method, conn.request_path) do
      nil ->
        conn

      feature ->
        started = System.monotonic_time(:microsecond)

        conn
        |> Plug.Conn.put_private(:mana_feature, feature)
        |> Plug.Conn.register_before_send(fn conn ->
          Mana.Feature.record(
            feature,
            conn.status || 200,
            System.monotonic_time(:microsecond) - started
          )

          conn
        end)
    end
  end

  defp cached_routes(otp_app, prefix) do
    key = {Mana.Feature, otp_app, prefix}

    case :persistent_term.get(key, nil) do
      nil ->
        routes = routes(Application.fetch_env!(otp_app, :ash_domains), prefix)
        :persistent_term.put(key, routes)
        routes

      routes ->
        routes
    end
  end

  @doc "The routes of `domains` under `prefix`, each with the feature it belongs to."
  def routes(domains, prefix) do
    for domain <- domains,
        route <- Info.routes(domain),
        feature = Mana.Feature.of_action(route.resource, route.action),
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

  defp segments(path), do: String.split(path, "/", trim: true)

  defp matches?(want, got) when length(want) == length(got),
    do: Enum.zip(want, got) |> Enum.all?(fn {w, g} -> String.starts_with?(w, ":") or w == g end)

  defp matches?(_want, _got), do: false
end
