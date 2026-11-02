defmodule ContractsTest.Notes do
  @moduledoc false
  use Ash.Domain, extensions: [AshJsonApi.Domain], validate_config_inclusion?: false

  json_api do
    routes do
      base_route "/notes", ContractsTest.Note do
        index :read
        get :read
        post :create
        route :post, "/archive", :archive
      end
    end
  end

  resources do
    resource ContractsTest.Note
  end
end

defmodule ContractsTest.Note do
  @moduledoc false
  use Ash.Resource,
    domain: ContractsTest.Notes,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "note"
  end

  attributes do
    uuid_primary_key :id
    attribute :body, :string, allow_nil?: false, public?: true
    attribute :title, :string, public?: true

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:open, :done]],
      default: :open

    attribute :due_at, Contracts.UtcDateTime, public?: true
  end

  actions do
    defaults [:read, create: [:body, :title, :status, :due_at]]

    action :archive do
      argument :reason, :string
      run fn _input, _context -> :ok end
    end
  end
end

defmodule ContractsTest.Tags do
  @moduledoc false
  use Ash.Domain, extensions: [AshJsonApi.Domain], validate_config_inclusion?: false

  json_api do
    routes do
      base_route "/tags", ContractsTest.Tag do
        index :read
      end
    end
  end

  resources do
    resource ContractsTest.Tag
  end
end

defmodule ContractsTest.Tag do
  @moduledoc false
  use Ash.Resource,
    domain: ContractsTest.Tags,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "tag"
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
  end

  actions do
    defaults [:read]
  end
end
