defmodule PostgresTest.ChatDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.ChatEntry)
    resource(PostgresTest.Thread)
    resource(PostgresTest.Note)
    resource(PostgresTest.Rating)
  end
end

defmodule PostgresTest.ChatEntry do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.ChatDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.History.Log]

  postgres do
    table("history_entries")
    repo(PostgresTest.Repo)
  end

  history_log do
    subjects([PostgresTest.Thread, PostgresTest.Rating])
  end
end

defmodule PostgresTest.Thread do
  @moduledoc false
  # One thread per topic: asking again counts on the same thread.
  use Ash.Resource,
    domain: PostgresTest.ChatDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Verbs, Mana.History]

  postgres do
    table("threads")
    repo(PostgresTest.Repo)
  end

  history do
    log(PostgresTest.ChatEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:topic, :string, allow_nil?: false, public?: true)
    attribute(:asks, :integer, default: 1, allow_nil?: false, public?: true)
  end

  identities do
    identity(:topic, [:topic])
  end

  relationships do
    has_many(:notes, PostgresTest.Note)
  end

  actions do
    defaults([:read])

    create :ask do
      accept([:topic])
      upsert?(true)
      upsert_identity(:topic)
      upsert_fields([:topic])
      change(atomic_update(:asks, expr(asks + 1)))
    end
  end

  verbs do
    verb(:ask, collection: true)
  end
end

defmodule PostgresTest.Note do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.ChatDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Verbs]

  postgres do
    table("notes")
    repo(PostgresTest.Repo)

    references do
      reference(:thread, on_delete: :restrict)
    end
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true)
  end

  relationships do
    belongs_to(:thread, PostgresTest.Thread, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
    create(:post, accept: [:thread_id, :body])
  end

  verbs do
    verb(:post, collection: true)
  end
end

defmodule PostgresTest.Rating do
  @moduledoc false
  # One rating per thread.
  use Ash.Resource,
    domain: PostgresTest.ChatDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Verbs, Mana.History]

  postgres do
    table("ratings")
    repo(PostgresTest.Repo)
  end

  history do
    log(PostgresTest.ChatEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:stars, :integer, public?: true, constraints: [min: 1, max: 5])
  end

  relationships do
    belongs_to(:thread, PostgresTest.Thread, allow_nil?: false, public?: true)
  end

  identities do
    identity(:thread, [:thread_id])
  end

  actions do
    defaults([:read])
    create(:rate, accept: [:thread_id, :stars])
  end

  verbs do
    verb(:rate, collection: true)
  end
end
