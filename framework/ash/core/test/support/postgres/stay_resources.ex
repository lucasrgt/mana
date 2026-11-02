defmodule PostgresTest.StayDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.StayEntry)
    resource(PostgresTest.Person)
    resource(PostgresTest.Stay)
  end
end

defmodule PostgresTest.StayEntry do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.StayDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.History.Log]

  postgres do
    table("history_entries")
    repo(PostgresTest.Repo)
  end

  history_log do
    subjects([PostgresTest.Person, PostgresTest.Stay])
  end
end

defmodule PostgresTest.Person do
  @moduledoc false
  # A user: the identity resource (its privacy subject is its key), with a
  # history of its own and a password the history keeps redacted.
  use Ash.Resource,
    domain: PostgresTest.StayDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Resource, Mana.History]

  postgres do
    table("people")
    repo(PostgresTest.Repo)
  end

  privacy do
    subject(:id)
    export([:name, :email, :phone, :role, :verified])
    personal([:name, :email, :phone])
    erase(:delete)
  end

  history do
    log(PostgresTest.StayEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:email, :string, allow_nil?: false, public?: true)
    attribute(:phone, :string, public?: true)

    attribute(:role, :atom,
      constraints: [one_of: [:host, :traveler]],
      allow_nil?: false,
      public?: true
    )

    attribute(:verified, :boolean, default: false, allow_nil?: false, public?: true)
    attribute(:hashed_password, :string, allow_nil?: false, sensitive?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :register do
      accept([:name, :email, :phone, :role])
      argument(:password, :string, allow_nil?: false, sensitive?: true)

      change(fn changeset, _ ->
        password = Ash.Changeset.get_argument(changeset, :password)
        Ash.Changeset.force_change_attribute(changeset, :hashed_password, "hashed:" <> password)
      end)
    end

    update(:verify, change: set_attribute(:verified, true))
  end
end

defmodule PostgresTest.StayLine do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:quantity, :integer, allow_nil?: false, public?: true)
    attribute(:amount_cents, :integer, allow_nil?: false, public?: true)
  end
end

defmodule PostgresTest.Stay do
  @moduledoc false
  # A booking between two people: lines priced into a total, a date, a
  # status, a note only the guest wrote.
  use Ash.Resource,
    domain: PostgresTest.StayDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Resource, Mana.History],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("stays")
    repo(PostgresTest.Repo)
  end

  privacy do
    subject(:traveler_id)
    export([:status, :total_cents, :lines, :scheduled_for, :guest_note, :paid])
    personal([:guest_note])
    erase(:keep)
    reason("the host keeps its bookings")
  end

  history do
    log(PostgresTest.StayEntry)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:status, :atom,
      constraints: [one_of: [:requested, :accepted, :cancelled]],
      default: :requested,
      allow_nil?: false,
      public?: true
    )

    attribute(:total_cents, :integer, allow_nil?: false, public?: true)

    attribute(:lines, {:array, PostgresTest.StayLine},
      default: [],
      allow_nil?: false,
      public?: true
    )

    attribute(:scheduled_for, :utc_datetime, allow_nil?: false, public?: true)
    attribute(:guest_note, :string, public?: true)
    attribute(:paid, :boolean, default: false, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:host, PostgresTest.Person, allow_nil?: false, public?: true)
    belongs_to(:traveler, PostgresTest.Person, allow_nil?: false, public?: true)
    belongs_to(:accepted_by, PostgresTest.Person, public?: true)
  end

  actions do
    defaults([:read])

    create :request do
      accept([:host_id, :lines, :scheduled_for, :guest_note])
      change(relate_actor(:traveler))

      change(fn changeset, _ ->
        total =
          changeset
          |> Ash.Changeset.get_attribute(:lines)
          |> Enum.map(&(&1.quantity * &1.amount_cents))
          |> Enum.sum()

        Ash.Changeset.force_change_attribute(changeset, :total_cents, total)
      end)
    end

    update :accept do
      require_atomic?(false)
      validate(attribute_equals(:status, :requested))
      change(set_attribute(:status, :accepted))
      change(set_attribute(:accepted_by_id, actor(:id)))
    end

    update(:pay, change: set_attribute(:paid, true))
    update(:cancel, change: set_attribute(:status, :cancelled))
  end

  policies do
    policy action(:accept) do
      authorize_if(actor_attribute_equals(:role, :host))
    end

    policy action_type([:read, :create, :update]) do
      authorize_if(always())
    end
  end
end
