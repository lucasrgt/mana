defmodule Mana.Session.CorsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import SessionTest.Http

  alias Mana.Session.Cors

  defp from(method, origin, options \\ []) do
    request(method, "/auth/sign-in")
    |> put_req_header("origin", origin)
    |> run(Cors, [otp_app: :mana_session] ++ options)
  end

  test "the configured origin is allowed, with the app's extra headers" do
    conn =
      from(:post, "http://app.test",
        request_headers: ["x-mana-data-scope"],
        response_headers: ["x-request-id"]
      )

    refute conn.halted
    assert get_resp_header(conn, "access-control-allow-origin") == ["http://app.test"]
    assert get_resp_header(conn, "vary") == ["origin"]

    assert get_resp_header(conn, "access-control-allow-methods") == [
             "GET,POST,PATCH,DELETE,OPTIONS"
           ]

    assert get_resp_header(conn, "access-control-allow-headers") == [
             "authorization,content-type,accept,x-mana-data-scope"
           ]

    assert get_resp_header(conn, "access-control-expose-headers") == ["retry-after,x-request-id"]
  end

  test "another origin gets no CORS headers" do
    for origin <- ["http://evil.test", "http://app.test.evil.test", "https://app.test"] do
      conn = from(:post, origin)
      refute conn.halted
      assert get_resp_header(conn, "access-control-allow-origin") == []
      assert get_resp_header(conn, "access-control-allow-headers") == []
    end
  end

  test "every preflight halts with 204, allowed or not" do
    for origin <- ["http://app.test", "http://evil.test"] do
      conn = from(:options, origin)
      assert conn.halted
      assert conn.status == 204
      assert conn.resp_body == ""
    end

    assert get_resp_header(from(:options, "http://app.test"), "access-control-allow-origin") ==
             ["http://app.test"]

    assert get_resp_header(from(:options, "http://evil.test"), "access-control-allow-origin") ==
             []
  end
end
