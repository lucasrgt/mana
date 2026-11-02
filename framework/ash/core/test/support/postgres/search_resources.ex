defmodule PostgresTest.SearchDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.Place)
  end
end

defmodule PostgresTest.Place do
  @moduledoc false
  use Ash.Resource, domain: PostgresTest.SearchDomain, data_layer: AshPostgres.DataLayer

  postgres do
    table("places")
    repo(PostgresTest.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, public?: true)
    attribute(:city, :string, public?: true)
    attribute(:tags, {:array, :string}, public?: true)
  end

  actions do
    defaults([:read, create: [:name, :city, :tags]])

    read :search_plain do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name, :city]})
    end

    read :search do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name, :city, :tags]})
    end

    read :search_unaccented do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name, :city, :tags], unaccent: true})
    end
  end
end
