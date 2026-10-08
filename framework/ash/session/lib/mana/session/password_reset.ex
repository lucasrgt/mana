defmodule Mana.Session.PasswordReset do
  @moduledoc """
  Serializes recovery for one account using its Postgres row. AshAuthentication
  owns token validation, hashing and revocation. User and token resources must
  use the same repository; no distributed transaction is implied.
  """

  def reset(resource, params) do
    strategy = AshAuthentication.Info.strategy!(resource, :password)
    token_resource = AshAuthentication.Info.authentication_tokens_token_resource!(resource)
    logout = AshAuthentication.Info.strategy!(resource, :log_out_everywhere)

    unless strategy.resettable &&
             is_nil(logout.include_purposes) && logout.exclude_purposes == ["revocation"] do
      raise ArgumentError, "Recovery requires resettable passwords and unrestricted logout"
    end

    unless Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer and
             Ash.DataLayer.data_layer(token_resource) == AshPostgres.DataLayer and
             AshPostgres.DataLayer.Info.repo(resource) ==
               AshPostgres.DataLayer.Info.repo(token_resource) and
             AshPostgres.DataLayer.Info.repo(resource, :read) ==
               AshPostgres.DataLayer.Info.repo(resource) and
             AshPostgres.DataLayer.Info.repo(token_resource, :read) ==
               AshPostgres.DataLayer.Info.repo(resource) do
      raise ArgumentError, "Password recovery requires user and tokens in one Postgres repository"
    end

    with %{"reset_token" => token} when is_binary(token) <- params,
         {:ok, %{"sub" => subject, "act" => action}, ^resource} <-
           AshAuthentication.Jwt.verify(token, resource),
         true <- action == to_string(strategy.resettable.password_reset_action_name),
         {:ok, user} <- AshAuthentication.subject_to_user(subject, resource) do
      case Ash.DataLayer.transaction(resource, fn ->
             # Verification above identifies a row, never authorizes a write.
             # Revalidate under the lock: another process may have consumed the
             # token while this process waited. Ash's reset action does that.
             with {:ok, %{__struct__: ^resource}} <-
                    resource
                    |> Ash.Query.filter_input(
                      Map.take(user, Ash.Resource.Info.primary_key(resource))
                    )
                    |> Ash.Query.lock(:for_update)
                    |> Ash.read_one(authorize?: false),
                  {:ok, updated} <- AshAuthentication.Strategy.action(strategy, :reset, params),
                  :ok <-
                    AshAuthentication.Strategy.action(logout, :log_out_everywhere, %{
                      user: updated
                    }) do
               :ok
             else
               _ -> Ash.DataLayer.rollback(resource, :reset_rejected)
             end
           end) do
        {:ok, :ok} -> :ok
        _ -> {:error, :reset_rejected}
      end
    else
      _ -> {:error, :reset_rejected}
    end
  end
end
