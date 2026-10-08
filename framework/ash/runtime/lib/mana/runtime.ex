defmodule Mana.Runtime do
  @moduledoc "Explicit production configuration shared by Ash/Phoenix consumers."
  def load!(get \\ &System.get_env/1) do
    database = required!(get, "DATABASE_URL")
    db = URI.parse(database)

    unless db.scheme in ["postgres", "postgresql"] and is_binary(db.host) and db.host != "" and
             is_binary(db.path) and db.path not in ["", "/"] and is_nil(db.query) and
             is_nil(db.fragment),
           do: invalid!("DATABASE_URL")

    ssl =
      case get.("DATABASE_SSL") || "require" do
        "require" ->
          trust =
            case get.("DATABASE_CA_CERT") do
              nil ->
                [cacerts: :public_key.cacerts_get()]

              path ->
                unless File.regular?(path), do: invalid!("DATABASE_CA_CERT")
                [cacertfile: String.to_charlist(path)]
            end

          [verify: :verify_peer, server_name_indication: String.to_charlist(db.host)] ++ trust

        "disable" ->
          unless loopback?(db.host), do: invalid!("DATABASE_SSL (disable requires loopback)")
          false

        _ ->
          invalid!("DATABASE_SSL")
      end

    public = origin!(get, "PUBLIC_ORIGIN")
    web = origin!(get, "WEB_ORIGIN")
    secret = required!(get, "SECRET_KEY_BASE")
    signing = required!(get, "TOKEN_SIGNING_SECRET")
    if byte_size(secret) < 64, do: invalid!("SECRET_KEY_BASE")
    if byte_size(signing) < 32 or signing == secret, do: invalid!("TOKEN_SIGNING_SECRET")
    address = get.("BIND_ADDRESS") || "127.0.0.1"

    ip =
      case :inet.parse_address(String.to_charlist(address)) do
        {:ok, value} -> value
        _ -> invalid!("BIND_ADDRESS")
      end

    %{
      repo: [
        url: database,
        ssl: ssl,
        pool_size: number!(get, "POOL_SIZE", 10, 1..100),
        show_sensitive_data_on_connection_error: false
      ],
      endpoint: [
        url: [scheme: public.scheme, host: public.host, port: public.port],
        http: [ip: ip, port: number!(get, "PORT", 4000, 1..65535)],
        secret_key_base: secret,
        server: true,
        check_origin: [URI.to_string(web)]
      ],
      web_origin: URI.to_string(web),
      trusted_proxy_ips: proxy_ips!(get.("TRUSTED_PROXY_IPS")),
      metrics_token: metrics_token!(get.("METRICS_TOKEN")),
      token_signing_secret: signing
    }
  end

  defp metrics_token!(nil), do: nil
  defp metrics_token!(value) when byte_size(value) in 32..128 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, value), do: value, else: invalid!("METRICS_TOKEN")
  end
  defp metrics_token!(_), do: invalid!("METRICS_TOKEN")

  defp proxy_ips!(nil), do: []
  defp proxy_ips!(""), do: []
  defp proxy_ips!("fly"), do: :fly

  defp proxy_ips!(value) when byte_size(value) <= 1024 do
    ips = String.split(value, ",")
    if length(ips) > 16, do: invalid!("TRUSTED_PROXY_IPS")

    Enum.map(ips, fn ip ->
      case :inet.parse_address(ip |> String.trim() |> String.to_charlist()) do
        {:ok, address} -> address
        _ -> invalid!("TRUSTED_PROXY_IPS")
      end
    end)
    |> Enum.uniq()
  end

  defp proxy_ips!(_), do: invalid!("TRUSTED_PROXY_IPS")

  defp required!(get, key) do
    case get.(key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> raise ArgumentError, "Missing production setting: #{key}"
    end
  end

  defp origin!(get, key) do
    value = required!(get, key)
    uri = URI.parse(value)

    unless uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             uri.path in [nil, "", "/"] and
             (uri.scheme == "https" or loopback?(uri.host)),
           do: invalid!(key)

    %{uri | path: nil}
  end

  defp number!(get, key, default, range) do
    case Integer.parse(get.(key) || Integer.to_string(default)) do
      {value, ""} -> if value in range, do: value, else: invalid!(key)
      _ -> invalid!(key)
    end
  end

  defp loopback?(host), do: host in ["localhost", "127.0.0.1", "::1"]
  defp invalid!(key), do: raise(ArgumentError, "Invalid production setting: #{key}")
end
