defmodule Mana.Runtime.Headers do
  @moduledoc """
  Transport headers for an API served without an edge that adds them (Fly.io's
  proxy does not): `nosniff` always, HSTS once the request is known to have
  arrived over HTTPS. Plug it after `Mana.Runtime.Proxy`, which sets the scheme.
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    conn = put_resp_header(conn, "x-content-type-options", "nosniff")
    if conn.scheme == :https, do: put_resp_header(conn, "strict-transport-security", "max-age=31536000"), else: conn
  end
end
