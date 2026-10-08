defmodule Mana.Runtime.MailTest do
  use ExUnit.Case, async: true

  defp settings do
    %{
      "MAIL_TRANSPORT" => "smtp",
      "SMTP_HOST" => "smtp.example.com",
      "SMTP_USERNAME" => "PRIVATE_USER",
      "SMTP_PASSWORD" => "PRIVATE_PASSWORD",
      "MAIL_FROM" => "accounts@example.com"
    }
  end

  defp load(values), do: Mana.Runtime.Mail.load!(&Map.get(values, &1))

  test "mail is disabled unless explicitly selected and SMTP never downgrades" do
    assert load(%{}) == %{mode: :disabled, mailer: [], from: nil}
    result = load(settings())
    assert result.mode == :smtp
    assert result.from == "accounts@example.com"
    config = result.mailer
    assert config[:port] == 587
    assert config[:ssl] == false
    assert config[:tls] == :always
    assert config[:auth] == :always
    assert config[:retries] == 0
    assert config[:no_mx_lookups]
    assert config[:tls_options][:verify] == :verify_peer
    assert config[:tls_options][:server_name_indication] == ~c"smtp.example.com"
    assert config[:tls_options][:versions] == [:"tlsv1.2", :"tlsv1.3"]
    assert is_function(config[:tls_options][:customize_hostname_check][:match_fun], 2)
  end

  test "invalid settings never echo their values" do
    for {key, value} <- [
          {"MAIL_TRANSPORT", "PRIVATE"},
          {"SMTP_HOST", "smtp://PRIVATE@smtp.example.com"},
          {"SMTP_HOST", "PRIVATE\r\nAUTH"},
          {"SMTP_PORT", "0"},
          {"SMTP_PORT", "65536"},
          {"SMTP_PORT", "587PRIVATE"},
          {"SMTP_USERNAME", ""},
          {"SMTP_PASSWORD", ""},
          {"MAIL_FROM", "PRIVATE\r\nBcc: x@example.com"},
          {"MAIL_FROM", "PRIVATE"},
          {"SMTP_CA_CERT", "/does-not-exist/PRIVATE"}
        ] do
      error = assert_raise ArgumentError, fn -> load(Map.put(settings(), key, value)) end
      assert Exception.message(error) == "Invalid mail setting: #{key}"
    end
  end
end
