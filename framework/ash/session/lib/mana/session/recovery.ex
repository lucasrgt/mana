defmodule Mana.Session.Recovery do
  @moduledoc "Optional recovery transport. The app owns asynchronous delivery."
  import Plug.Conn

  def init(options), do: Map.new(options)

  def call(conn, %{action: :request, enqueue: {module, function}}) do
    with %{"email" => email} when is_binary(email) and byte_size(email) <= 254 <-
           conn.body_params,
         email = String.trim(email),
         true <- Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/u, email) do
      # Enqueue both existing and unknown identities, before any account lookup.
      case apply(module, function, [email]) do
        :ok -> json(conn, 202, %{status: "accepted"})
        _ -> json(conn, 503, %{error: "recovery_unavailable"})
      end
    else
      _ -> json(conn, 422, %{error: "invalid_request"})
    end
  end

  def call(conn, %{action: :reset, user: resource}) do
    with %{"token" => token, "password" => password, "passwordConfirmation" => confirmation} <-
           conn.body_params,
         true <- is_binary(token) and byte_size(token) in 1..8191,
         true <- is_binary(password) and byte_size(password) <= 72,
         true <- is_binary(confirmation) and byte_size(confirmation) <= 72,
         :ok <-
           Mana.Session.PasswordReset.reset(resource, %{
             "reset_token" => token,
             "password" => password,
             "password_confirmation" => confirmation
           }) do
      conn |> put_resp_header("cache-control", "no-store") |> send_resp(204, "")
    else
      _ -> json(conn, 422, %{error: "reset_rejected"})
    end
  end

  defp json(conn, status, data),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(data))
end
