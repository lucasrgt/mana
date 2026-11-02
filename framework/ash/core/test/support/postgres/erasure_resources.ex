defmodule PostgresTest.ErasureDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.ErasureFile)
  end
end

defmodule PostgresTest.ErasureFile do
  @moduledoc false
  # A person's uploads, erased with them.
  use Ash.Resource,
    domain: PostgresTest.ErasureDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Resource, Mana.Uploads]

  postgres do
    table("erasure_files")
    repo(PostgresTest.Repo)
  end

  privacy do
    subject(:owner_id)
    erase(:delete)
  end

  uploads do
    kind(:photo, thumbnail: 64)
  end
end
