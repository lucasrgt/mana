defmodule Mana.Session.Throttle do
  @moduledoc "Credential admission before bcrypt. Login and registration share bounded budgets."
  import Plug.Conn
  @window 60_000
  def init(options), do: Map.new(options)

  def call(%{method: "POST", path_info: ["auth", action]} = conn, %{scope: :ip} = options)
      when action in ["sign-in", "sign-up", "request-password-reset", "reset-password", "request-confirmation", "confirm-email"],
      do: admit(conn, options, {:ip, conn.remote_ip}, 30)

  def call(conn, %{scope: :ip}), do: conn

  def call(conn, %{scope: :account, otp_app: otp_app} = options) do
    case conn.body_params do
      %{"email" => email} when is_binary(email) and byte_size(email) <= 254 ->
        # No emails/passwords in counter keys, logs or Retry-After responses.
        secret = Application.fetch_env!(otp_app, :token_signing_secret)
        digest = :crypto.mac(:hmac, :sha256, secret, email |> String.trim() |> String.downcase())
        admit(conn, options, {:account, digest}, 6)

      _ ->
        conn
    end
  end

  defp admit(conn, %{limiter: limiter}, key, budget) do
    case limiter.hit(key, @window, budget) do
      {:allow, _} ->
        conn

      {:deny, milliseconds} ->
        conn
        |> put_resp_header(
          "retry-after",
          Integer.to_string(max(1, div(milliseconds + 999, 1000)))
        )
        |> reject(429, "rate_limited")
    end
  rescue
    ArgumentError -> reject(conn, 503, "sign_in_unavailable")
  catch
    :exit, _ -> reject(conn, 503, "sign_in_unavailable")
  end

  defp reject(conn, status, error) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
