defmodule Mana.Runtime.Proxy do
  @moduledoc """
  One trusted edge proxy, using native Plug rewriting after checking the socket
  peer. The edge must replace incoming X-Forwarded-For/Proto with one client IP
  and its observed scheme. No implicit trust of loopback or private networks.

  On Fly.io (`TRUSTED_PROXY_IPS=fly`) the proxy appends to a client's own
  X-Forwarded-For instead, and its peer address is not fixed; the client is
  the `Fly-Client-IP` it sets, which only holds while the app's port is
  reachable through Fly's proxy alone.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: Keyword.fetch!(options, :otp_app)

  @impl true
  def call(conn, app) do
    case Application.get_env(app, :trusted_proxy_ips, []) do
      :fly ->
        fly(conn, get_req_header(conn, "fly-client-ip"), get_req_header(conn, "x-forwarded-proto"))

      trusted ->
        if trusted != [] and get_peer_data(conn).address in trusted do
          rewrite(conn, get_req_header(conn, "x-forwarded-for"), get_req_header(conn, "x-forwarded-proto"))
        else
          conn
        end
    end
  end

  defp fly(conn, [], _), do: conn

  defp fly(conn, [ip], [scheme]) when byte_size(ip) <= 45 and scheme in ["http", "https"] do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, address} -> Plug.RewriteOn.call(%{conn | remote_ip: address}, [:x_forwarded_proto])
      _ -> reject(conn)
    end
  end

  defp fly(conn, _, _), do: reject(conn)

  # Direct internal readiness requests need no forwarded identity.
  defp rewrite(conn, [], []), do: conn

  defp rewrite(conn, [ip], [scheme]) when byte_size(ip) <= 45 and scheme in ["http", "https"] do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, _} -> Plug.RewriteOn.call(conn, [:x_forwarded_for, :x_forwarded_proto])
      _ -> reject(conn)
    end
  end

  defp rewrite(conn, _, _), do: reject(conn)
  defp reject(conn), do: conn |> send_resp(400, "Invalid proxy headers") |> halt()
end
