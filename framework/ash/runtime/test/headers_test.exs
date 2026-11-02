defmodule Mana.Runtime.HeadersTest do
  use ExUnit.Case, async: true
  alias Mana.Runtime.Headers
  import Plug.Test

  test "nosniff always, HSTS only over HTTPS" do
    plain = Headers.call(conn(:get, "/"), [])
    assert Plug.Conn.get_resp_header(plain, "x-content-type-options") == ["nosniff"]
    assert Plug.Conn.get_resp_header(plain, "strict-transport-security") == []
    secure = Headers.call(%{conn(:get, "/") | scheme: :https}, [])
    assert Plug.Conn.get_resp_header(secure, "strict-transport-security") == ["max-age=31536000"]
  end
end
