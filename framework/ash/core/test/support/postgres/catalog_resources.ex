defmodule PostgresTest.CatalogDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.CatalogEntry)
    resource(PostgresTest.Venue)
    resource(PostgresTest.Offering)
  end
end

defmodule PostgresTest.CatalogEntry do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.CatalogDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.History.Log]

  postgres do
    table("history_entries")
    repo(PostgresTest.Repo)
  end

  history_log do
    subjects([PostgresTest.Venue, PostgresTest.Offering])
  end
end

defmodule PostgresTest.Venue.OfferingPublished do
  @moduledoc false
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    venue = changeset.data.id

    if PostgresTest.Offering
       |> Ash.Query.filter(venue_id == ^venue and status == :published)
       |> Ash.exists?(authorize?: false),
       do: :ok,
       else:
         {:error,
          Mana.Error.new(
            "catalog.offering_required_to_publish",
            "a venue is published once one of its offerings is"
          )}
  end
end

defmodule PostgresTest.Venue do
  @moduledoc false
  # A place whose publication needs one of its offerings published first:
  # its history alone cannot rebuild it, only together with theirs. Its
  # timestamp has second precision, so venues made together tie on it.
  use Ash.Resource,
    domain: PostgresTest.CatalogDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.History, Mana.Verbs]

  postgres do
    table("venues")
    repo(PostgresTest.Repo)
  end

  history do
    log(PostgresTest.CatalogEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:draft, :published]],
      default: :draft,
      allow_nil?: false,
      public?: true
    )

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
  end

  relationships do
    has_many(:offerings, PostgresTest.Offering)
  end

  actions do
    defaults([:read])
    create(:open, accept: [:name])
    update(:rename, accept: [:name])

    update :publish do
      require_atomic?(false)
      validate(PostgresTest.Venue.OfferingPublished)
      change(set_attribute(:status, :published))
    end
  end

  verbs do
    verb(:open, collection: true)
    verb(:rename)
    verb(:publish, when: expr(status == :draft and exists(offerings, status == :published)))
  end
end

defmodule PostgresTest.Offering do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.CatalogDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.History, Mana.Verbs]

  postgres do
    table("offerings")
    repo(PostgresTest.Repo)
  end

  history do
    log(PostgresTest.CatalogEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:draft, :published]],
      default: :draft,
      allow_nil?: false,
      public?: true
    )
  end

  relationships do
    belongs_to(:venue, PostgresTest.Venue, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
    create(:add, accept: [:venue_id, :title])
    update(:publish, change: set_attribute(:status, :published))
  end

  verbs do
    verb(:add, collection: true, from: {PostgresTest.Venue, :venue_id})
    verb(:publish, when: expr(status == :draft))
  end
end
