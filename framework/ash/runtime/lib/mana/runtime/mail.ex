defmodule Mana.Runtime.Mail do
  @moduledoc "Optional SMTP configuration. STARTTLS, authentication and peer verification are mandatory."

  def load!(get \\ &System.get_env/1) do
    case get.("MAIL_TRANSPORT") || "disabled" do
      "disabled" -> %{mode: :disabled, mailer: [], from: nil}
      "smtp" -> smtp!(get)
      _ -> invalid!("MAIL_TRANSPORT")
    end
  end

  defp smtp!(get) do
    relay = required!(get, "SMTP_HOST")

    # Accept a relay hostname, never a URL, credentials or SMTP command text.
    unless byte_size(relay) <= 253 and
             Regex.match?(~r/\A[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?\z/, relay),
           do: invalid!("SMTP_HOST")

    from = required!(get, "MAIL_FROM")

    unless byte_size(from) <= 254 and
             Regex.match?(~r/\A[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+\z/u, from),
           do: invalid!("MAIL_FROM")

    trust =
      case get.("SMTP_CA_CERT") do
        nil ->
          [cacerts: :public_key.cacerts_get()]

        path ->
          unless File.regular?(path), do: invalid!("SMTP_CA_CERT")
          [cacertfile: String.to_charlist(path)]
      end

    tls =
      [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        verify: :verify_peer,
        server_name_indication: String.to_charlist(relay),
        depth: 10,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ trust

    port =
      case Integer.parse(get.("SMTP_PORT") || "587") do
        {value, ""} when value in 1..65535 -> value
        _ -> invalid!("SMTP_PORT")
      end

    %{
      mode: :smtp,
      from: from,
      mailer: [
        adapter: Swoosh.Adapters.SMTP,
        relay: relay,
        port: port,
        username: required!(get, "SMTP_USERNAME"),
        password: required!(get, "SMTP_PASSWORD"),
        ssl: false,
        tls: :always,
        tls_options: tls,
        auth: :always,
        timeout: 5_000,
        no_mx_lookups: true,
        retries: 0
      ]
    }
  end

  defp required!(get, key) do
    case get.(key) do
      value when is_binary(value) and byte_size(value) > 0 -> value
      _ -> invalid!(key)
    end
  end

  defp invalid!(key), do: raise(ArgumentError, "Invalid mail setting: #{key}")
end
