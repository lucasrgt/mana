defmodule Mana.Session.Confirmation do
  @moduledoc "Opt-in email confirmation. Ash owns capabilities; confirmation never signs in."
  import Plug.Conn

  def init(options), do: Map.new(options)

  def call(conn, %{action: :request, enqueue: {module, function}}) do
    with %{"email" => email} when is_binary(email) and byte_size(email) <= 254 <-
           conn.body_params,
         email = String.trim(email),
         true <- Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/u, email) do
      case apply(module, function, [email]) do
        :ok -> json(conn, 202, %{status: "accepted"})
        _ -> json(conn, 503, %{error: "confirmation_unavailable"})
      end
    else
      _ -> json(conn, 422, %{error: "invalid_request"})
    end
  end

  def call(conn, %{action: :confirm, user: resource, strategy: name}) do
    with %{"token" => token} when is_binary(token) and byte_size(token) in 1..8191 <-
           conn.body_params,
         :ok <- confirm(resource, name, token) do
      conn |> put_resp_header("cache-control", "no-store") |> send_resp(204, "")
    else
      _ -> json(conn, 422, %{error: "confirmation_rejected"})
    end
  end

  def confirm(resource, name, token) do
    strategy = AshAuthentication.Info.strategy!(resource, name)
    tokens = AshAuthentication.Info.authentication_tokens_token_resource!(resource)
    logout = AshAuthentication.Info.strategy!(resource, :log_out_everywhere)

    unless supported?(resource, tokens, strategy, logout),
      do:
        raise(
          ArgumentError,
          "Confirmation requires one Postgres repository and unrestricted logout"
        )

    with {:ok, %{"sub" => subject, "act" => action}, ^resource} <-
           AshAuthentication.Jwt.verify(token, resource),
         true <- action == to_string(strategy.confirm_action_name),
         {:ok, user} <- AshAuthentication.subject_to_user(subject, resource),
         {:ok, :ok} <-
           Ash.DataLayer.transaction(resource, fn ->
             confirm_locked(resource, user, strategy, logout, token)
           end) do
      :ok
    else
      _ -> {:error, :confirmation_rejected}
    end
  end

  defp supported?(resource, tokens, strategy, logout) do
    is_struct(strategy, AshAuthentication.AddOn.Confirmation) and
      is_nil(logout.include_purposes) and logout.exclude_purposes == ["revocation"] and
      Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer and
      Ash.DataLayer.data_layer(tokens) == AshPostgres.DataLayer and
      Enum.all?([resource, tokens], &same_repo?(&1, resource))
  end

  defp same_repo?(target, resource) do
    AshPostgres.DataLayer.Info.repo(target) == AshPostgres.DataLayer.Info.repo(resource) and
      AshPostgres.DataLayer.Info.repo(target, :read) == AshPostgres.DataLayer.Info.repo(resource)
  end

  # The first verification only locates the account. Ash validates again
  # under this lock, serializing confirmation with password recovery.
  defp confirm_locked(resource, user, strategy, logout, token) do
    with {:ok, %{__struct__: ^resource} = locked} <- lock(resource, user, strategy),
         true <- is_nil(Map.get(locked, strategy.confirmed_at_field)),
         {:ok, updated} <-
           AshAuthentication.Strategy.action(strategy, :confirm, %{"confirm" => token}),
         :ok <- AshAuthentication.Strategy.action(logout, :log_out_everywhere, %{user: updated}) do
      :ok
    else
      _ -> Ash.DataLayer.rollback(resource, :confirmation_rejected)
    end
  end

  defp lock(resource, user, strategy) do
    resource
    |> Ash.Query.filter_input(Map.take(user, Ash.Resource.Info.primary_key(resource)))
    |> Ash.Query.ensure_selected([strategy.confirmed_at_field])
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp json(conn, status, body),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(body))
end
