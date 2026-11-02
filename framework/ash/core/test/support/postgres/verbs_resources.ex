defmodule PostgresTest.VerbsDomain do
  @moduledoc false
  # The offer's own resources: a shelf whose verbs read an aggregate, the
  # actor and a child's condition, on tables `create_tables!/1`
  # adds to the harness database.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.VerbsShelf)
    resource(PostgresTest.VerbsBook)
  end

  def create_tables!(repo) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS verbs_shelves (
      id uuid PRIMARY KEY, owner_id uuid NOT NULL, status text NOT NULL DEFAULT 'open')
    """)

    repo.query!(
      "CREATE TABLE IF NOT EXISTS verbs_books (id uuid PRIMARY KEY, shelf_id uuid NOT NULL)"
    )

    :ok
  end

  def truncate!(repo) do
    repo.query!("TRUNCATE verbs_shelves, verbs_books")
    :ok
  end
end

defmodule PostgresTest.VerbsShelf do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.VerbsDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Verbs],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("verbs_shelves")
    repo(PostgresTest.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      allow_nil?: false,
      public?: true
    )
  end

  relationships do
    has_many(:books, PostgresTest.VerbsBook, destination_attribute: :shelf_id)
  end

  aggregates do
    count(:book_count, :books)
  end

  actions do
    defaults([:read, create: [:owner_id, :status]])
    update(:close, change: set_attribute(:status, :closed))
    update(:reopen, change: set_attribute(:status, :open))
    update(:tidy)
    update(:claim)
  end

  verbs do
    verb(:close, when: expr(status == :open))
    verb(:reopen, when: expr(status == :closed))
    verb(:tidy, when: expr(book_count > 1))
    verb(:claim, when: expr(status == :open and owner_id == ^actor(:id)))
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:close, :reopen]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    policy action([:tidy, :claim]) do
      authorize_if(always())
    end
  end
end

defmodule PostgresTest.VerbsBook do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.VerbsDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Verbs],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("verbs_books")
    repo(PostgresTest.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:shelf_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:shelf_id]])
  end

  verbs do
    verb(:create,
      collection: true,
      from: {PostgresTest.VerbsShelf, :shelf_id},
      when: expr(status == :open)
    )
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(actor_present())
    end
  end
end
