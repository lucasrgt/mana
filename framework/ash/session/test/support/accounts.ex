defmodule SessionTest.Repo do
  @moduledoc false
  use AshPostgres.Repo, otp_app: :mana_session

  def installed_extensions, do: ["ash-functions", "citext"]
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule SessionTest.Secrets do
  @moduledoc false
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], _resource, _opts, _context),
    do: Application.fetch_env(:mana_session, :token_signing_secret)
end

defmodule SessionTest.Sender do
  @moduledoc "Hands every emailed token to the process that ran the action, so a test can use it."
  use AshAuthentication.Sender

  @impl true
  def send(user, token, opts),
    do: Kernel.send(self(), {opts[:kind], to_string(user.email), token})
end

defmodule SessionTest.Accounts do
  @moduledoc false
  use Ash.Domain, otp_app: :mana_session

  resources do
    resource SessionTest.Token
    resource SessionTest.User
    resource SessionTest.ConfirmedUser
  end
end

defmodule SessionTest.Token do
  @moduledoc false
  use Ash.Resource,
    domain: SessionTest.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "tokens"
    repo SessionTest.Repo
  end

  actions do
    defaults [:read]
  end
end

defmodule SessionTest.User do
  @moduledoc "Email/password sessions with recovery, the shape `Mana.Session` documents."
  use Ash.Resource,
    domain: SessionTest.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  postgres do
    table "users"
    repo SessionTest.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :hashed_password, :string, allow_nil?: false, sensitive?: true
  end

  identities do
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read]
  end

  authentication do
    session_identifier :jti

    tokens do
      enabled? true
      token_resource SessionTest.Token
      store_all_tokens? true
      require_token_presence_for_authentication? true
      signing_secret SessionTest.Secrets
    end

    strategies do
      password :password do
        identity_field :email

        resettable do
          sender {SessionTest.Sender, kind: :reset}
        end
      end
    end

    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end
  end
end

defmodule SessionTest.ConfirmedUser do
  @moduledoc "The opt-in confirmation shape: sign-in and Bearer identity wait for `confirmed_at`."
  use Ash.Resource,
    domain: SessionTest.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication]

  postgres do
    table "confirmed_users"
    repo SessionTest.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :ci_string, allow_nil?: false, public?: true
    attribute :hashed_password, :string, allow_nil?: false, sensitive?: true
  end

  identities do
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read]
  end

  authentication do
    session_identifier :jti

    tokens do
      enabled? true
      token_resource SessionTest.Token
      store_all_tokens? true
      require_token_presence_for_authentication? true
      signing_secret SessionTest.Secrets
    end

    strategies do
      password :password do
        identity_field :email
        require_confirmed_with :confirmed_at

        resettable do
          sender {SessionTest.Sender, kind: :reset}
        end
      end
    end

    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end

      confirmation :confirm_new_user do
        monitor_fields [:email]
        confirm_on_create? true
        confirm_on_update? false
        require_interaction? true
        sender {SessionTest.Sender, kind: :confirm}
      end
    end
  end
end
