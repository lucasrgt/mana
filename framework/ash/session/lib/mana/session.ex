defmodule Mana.Session do
  @moduledoc "Opinionated JSON session transport; credentials and tokens are managed by AshAuthentication."
  import Plug.Conn

  def init(options) do
    action = Keyword.fetch!(options, :action)

    unless action in [:sign_up, :sign_in, :show, :sign_out],
      do: raise(ArgumentError, "Unknown session action")

    %{
      action: action,
      confirmation: Keyword.get(options, :confirmation, false),
      user: Keyword.fetch!(options, :user),
      token: Keyword.fetch!(options, :token)
    }
  end

  def call(conn, %{action: :sign_up, user: resource} = options) do
    with %{"email" => email, "password" => password, "passwordConfirmation" => confirmation} <-
           conn.body_params,
         true <- is_binary(email) and byte_size(email) <= 254,
         true <- is_binary(password) and byte_size(password) <= 72,
         true <- is_binary(confirmation) and byte_size(confirmation) <= 72 do
      strategy = AshAuthentication.Info.strategy!(resource, :password)

      case AshAuthentication.Strategy.action(strategy, :register, %{
             email: String.trim(email),
             password: password,
             password_confirmation: confirmation
           }) do
        {:ok, user} ->
          token = user.__metadata__.token
          json(conn, 201, Map.put(view(user, token), :accessToken, token))

        {:error, %AshAuthentication.Errors.AuthenticationFailed{
          caused_by: %AshAuthentication.Errors.UnconfirmedUser{}}} when options.confirmation ->
          json(conn, 202, %{status: "confirmation_required"})

        {:error, %Ash.Error.Invalid{}} ->
          json(conn, 422, %{error: "registration_rejected"})

        {:error, _} ->
          json(conn, 503, %{error: "registration_unavailable"})
      end
    else
      _ -> json(conn, 422, %{error: "registration_rejected"})
    end
  end

  def call(conn, %{action: :sign_in, user: resource}) do
    with %{"email" => email, "password" => password} <- conn.body_params,
         true <- is_binary(email) and byte_size(email) <= 254,
         true <- is_binary(password) and byte_size(password) <= 72,
         strategy <- AshAuthentication.Info.strategy!(resource, :password),
         {:ok, user} <-
           AshAuthentication.Strategy.action(strategy, :sign_in, %{
             email: email,
             password: password
           }) do
      token = user.__metadata__.token
      json(conn, 200, Map.put(view(user, token), :accessToken, token))
    else
      _ -> json(conn, 401, %{error: "invalid_credentials"})
    end
  end

  def call(conn, %{action: :show}),
    do: json(conn, 200, view(Ash.PlugHelpers.get_actor(conn), conn.assigns.access_token))

  def call(conn, %{action: :sign_out, token: resource}) do
    case AshAuthentication.TokenResource.Actions.revoke(resource, conn.assigns.access_token) do
      :ok -> conn |> put_resp_header("cache-control", "no-store") |> send_resp(204, "")
      {:error, _} -> json(conn, 503, %{error: "sign_out_unavailable"})
    end
  end

  defp view(user, token) do
    {:ok, claims} = AshAuthentication.Jwt.peek(token)

    %{
      userId: user.id,
      email: to_string(user.email),
      expiresAt: DateTime.from_unix!(claims["exp"])
    }
  end

  defp json(conn, status, data),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(data))
end
