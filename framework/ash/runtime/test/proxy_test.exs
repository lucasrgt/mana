defmodule Mana.Runtime.ProxyTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  setup do
    Application.put_env(:mana_runtime_proxy_test, :trusted_proxy_ips, [{127, 0, 0, 1}])
    on_exit(fn -> Application.delete_env(:mana_runtime_proxy_test, :trusted_proxy_ips) end)
    :ok
  end

  defp call(conn), do: Mana.Runtime.Proxy.call(conn, :mana_runtime_proxy_test)
  defp forwarded(conn, ip \\ "198.51.100.9"),
    do: conn |> put_req_header("x-forwarded-for", ip) |> put_req_header("x-forwarded-proto", "https")

  test "trusted socket peer supplies client identity and TLS scheme through native Plug" do
    result = conn(:get, "/") |> forwarded() |> call()
    assert result.remote_ip == {198, 51, 100, 9}
    assert result.scheme == :https
    assert result.host == "www.example.com"
    refute result.halted
  end

  test "forged identity cannot make an untrusted socket peer trusted" do
    connection = conn(:get, "/") |> forwarded()
    {adapter, payload} = connection.adapter
    payload = put_in(payload.peer_data.address, {203, 0, 113, 1})
    connection = %{connection | adapter: {adapter, payload}, remote_ip: {127, 0, 0, 1}}
    result = call(connection)
    assert result.remote_ip == connection.remote_ip
    assert result.scheme == :http
  end

  test "no proxy is trusted by default, and internal probes retain their socket identity" do
    Application.delete_env(:mana_runtime_proxy_test, :trusted_proxy_ips)
    assert (conn(:get, "/") |> forwarded() |> call()).remote_ip == {127, 0, 0, 1}
    Application.put_env(:mana_runtime_proxy_test, :trusted_proxy_ips, [{127, 0, 0, 1}])
    probe = conn(:get, "/readyz")
    assert call(probe) == probe
  end

  test "chains, duplicate headers and incomplete metadata from a trusted edge are rejected" do
    base = conn(:get, "/")
    duplicate = %{base | req_headers: [{"x-forwarded-for", "198.51.100.1"}, {"x-forwarded-for", "198.51.100.2"}, {"x-forwarded-proto", "https"}]}
    for invalid <- [forwarded(base, "198.51.100.1, 198.51.100.2"), forwarded(base, "untrusted.example"),
                    put_req_header(base, "x-forwarded-for", "198.51.100.1"), duplicate] do
      result = call(invalid)
      assert result.status == 400
      assert result.halted
    end
  end

  test "on Fly the client is the proxy's Fly-Client-IP, whatever X-Forwarded-For carries" do
    Application.put_env(:mana_runtime_proxy_test, :trusted_proxy_ips, :fly)
    fly = fn ip -> conn(:get, "/") |> put_req_header("x-forwarded-for", "10.0.0.1, #{ip}") |> put_req_header("fly-client-ip", ip) |> put_req_header("x-forwarded-proto", "https") end
    result = call(fly.("2001:db8::7"))
    assert result.remote_ip == {8193, 3512, 0, 0, 0, 0, 0, 7}
    assert result.scheme == :https
    refute result.halted
    probe = conn(:get, "/readyz")
    assert call(probe) == probe
    for invalid <- [fly.("not-an-ip"), put_req_header(conn(:get, "/"), "fly-client-ip", "198.51.100.1")] do
      assert call(invalid).status == 400
    end
  end
end
