defmodule Mana.Runtime.MetricsPlug do
  @moduledoc "Explicit internal scrape endpoint; disabled without a dedicated token."
  import Plug.Conn
  @behaviour Plug

  def init(options), do: {Keyword.fetch!(options, :otp_app), Keyword.fetch!(options, :name)}

  def call(%{request_path: "/metrics"} = conn, {app, name}) do
    token = Application.get_env(app, :metrics_token)

    cond do
      is_nil(token) -> respond(conn, 404, "")
      conn.method != "GET" -> respond(conn, 405, "")
      not authorized?(conn, token) -> respond(conn, 401, "")
      true ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> respond(200, Mana.Runtime.Metrics.scrape(name))
    end
  end

  def call(conn, _), do: conn

  defp authorized?(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] when byte_size(supplied) == byte_size(token) ->
        Plug.Crypto.secure_compare(supplied, token)
      _ -> false
    end
  end

  defp respond(conn, status, body),
    do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(status, body) |> halt()
end
