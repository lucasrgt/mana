defmodule Mana.RuntimeTest do
  use ExUnit.Case, async: true

  defp base do
    %{
      "DATABASE_URL" => "postgres://user:PRIVATE@db.example/tasks",
      "PUBLIC_ORIGIN" => "https://api.example",
      "WEB_ORIGIN" => "https://app.example",
      "SECRET_KEY_BASE" => String.duplicate("s", 64),
      "TOKEN_SIGNING_SECRET" => String.duplicate("t", 32)
    }
  end

  defp load(values), do: Mana.Runtime.load!(&Map.get(values, &1))

  test "production uses peer verification and never accepts plaintext remote transports" do
    config = load(base())
    assert config.repo[:ssl][:verify] == :verify_peer
    assert config.repo[:ssl][:server_name_indication] == ~c"db.example"
    assert config.repo[:show_sensitive_data_on_connection_error] == false

    for {key, value} <- [
          {"DATABASE_SSL", "disable"},
          {"WEB_ORIGIN", "http://app.example"},
          {"PUBLIC_ORIGIN", "https://api.example/path"},
          {"PUBLIC_ORIGIN", "https://private@api.example"},
          {"DATABASE_URL", "postgres://user:PRIVATE@db.example/tasks?ssl=false"},
          {"SECRET_KEY_BASE", "short"},
          {"TOKEN_SIGNING_SECRET", "short"},
          {"PORT", "0"},
          {"POOL_SIZE", "999"}
        ] do
      assert_raise ArgumentError, fn -> load(Map.put(base(), key, value)) end
    end
  end

  test "local release proof is explicit and diagnostics never echo credentials" do
    values =
      Map.merge(base(), %{
        "DATABASE_URL" => "postgres://user:PRIVATE@127.0.0.1/tasks",
        "DATABASE_SSL" => "disable",
        "PUBLIC_ORIGIN" => "http://127.0.0.1:5208",
        "WEB_ORIGIN" => "http://127.0.0.1:5206"
      })

    assert load(values).repo[:ssl] == false
    error = assert_raise ArgumentError, fn -> load(Map.put(values, "DATABASE_URL", "PRIVATE")) end
    refute Exception.message(error) =~ "PRIVATE"
    assert_raise ArgumentError, fn -> load(Map.delete(values, "TOKEN_SIGNING_SECRET")) end
  end

  test "edge trust requires explicit bounded IP literals" do
    assert load(base()).trusted_proxy_ips == []
    assert load(Map.put(base(), "TRUSTED_PROXY_IPS", "127.0.0.1, ::1")).trusted_proxy_ips ==
             [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

    assert load(Map.put(base(), "TRUSTED_PROXY_IPS", "fly")).trusted_proxy_ips == :fly

    for value <- ["private_ranges", "10.0.0.0/8", "proxy.example", "127.0.0.1,", String.duplicate("1", 1025)] do
      assert_raise ArgumentError, "Invalid production setting: TRUSTED_PROXY_IPS", fn ->
        load(Map.put(base(), "TRUSTED_PROXY_IPS", value))
      end
    end
  end

  test "scrape token is optional, bounded and absent from configuration errors" do
    assert load(base()).metrics_token == nil
    token = String.duplicate("a", 64)
    assert load(Map.put(base(), "METRICS_TOKEN", token)).metrics_token == token
    for value <- ["", "short", String.duplicate("a", 129), String.duplicate("a", 32) <> "\n"] do
      assert_raise ArgumentError, "Invalid production setting: METRICS_TOKEN", fn ->
        load(Map.put(base(), "METRICS_TOKEN", value))
      end
    end
  end
end
