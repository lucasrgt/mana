defmodule Mana.Session.Identity do
  @moduledoc "Bearer verification, expiry and revocation are owned by AshAuthentication."
  import Plug.Conn
  def init(options), do: options

  def call(conn, options) do
    # Refuse ambiguous credentials before delegating signature, purpose, stored
    # token presence, expiration and subject resolution to the library.
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- byte_size(token) > 0 and byte_size(token) < 8192,
         {:ok, actor} <- resolve(token, options) do
      conn |> Ash.PlugHelpers.set_actor(actor) |> assign(:access_token, token)
    else
      _ ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthenticated"}))
        |> halt()
    end
  end

  def resolve(token, options) do
    resource = Keyword.fetch!(options, :user)
    otp_app = Keyword.fetch!(options, :otp_app)

    with true <- resource in AshAuthentication.authenticated_resources(otp_app),
         {:ok, subject} when is_atom(subject) and not is_nil(subject) <-
           AshAuthentication.Info.authentication_subject_name(resource) do
      conn =
        %Plug.Conn{}
        |> put_req_header("authorization", "Bearer " <> token)
        |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(otp_app)

      expected = "current_" <> Atom.to_string(subject)

      Enum.find_value(conn.assigns, fn
        {key, %{__struct__: ^resource} = user} ->
          if Atom.to_string(key) == expected and confirmed?(resource, user), do: {:ok, user}

        _ ->
          nil
      end) || {:error, :unauthenticated}
    else
      _ -> {:error, :unauthenticated}
    end
  end

  # Password sign-in checks confirmation, but an already issued Bearer token
  # takes another path. Query the database predicate, not a possibly unselected
  # or hidden attribute on the resolved record.
  defp confirmed?(resource, user) do
    case AshAuthentication.Info.strategy(resource, :password) do
      {:ok, %{require_confirmed_with: field} = strategy} when not is_nil(field) ->
        alias AshAuthentication.Strategy.Password.RequireConfirmed

        resource
        |> Ash.Query.filter_input(Map.take(user, Ash.Resource.Info.primary_key(resource)))
        |> RequireConfirmed.add_calculation(strategy)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, %{__struct__: ^resource} = record} -> RequireConfirmed.confirmed?(record, strategy)
          _ -> false
        end

      _ -> true
    end
  end
end
