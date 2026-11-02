defmodule PostgresTest.SearchDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.Place)
  end
end

defmodule PostgresTest.Service do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute(:label, :string, public?: true)
    attribute(:note, :string, public?: true)
    attribute(:price, :integer, public?: true)
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
    attribute(:services, {:array, PostgresTest.Service}, public?: true)
    attribute(:featured, PostgresTest.Service, public?: true)
  end

  actions do
    defaults([:read, create: [:name, :city, :tags, :services, :featured]])

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

    read :search_services do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name, services: [:label, :note], featured: :label]})
    end

    read :search_services_unaccented do
      argument(:q, :string)
      prepare({Mana.Search, fields: [:name, services: :label, featured: :label], unaccent: true})
    end

    read :search_service_price do
      argument(:q, :string)
      prepare({Mana.Search, fields: [services: :cost]})
    end
  end
end
