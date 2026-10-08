defmodule __Name__.Notes do
  @moduledoc "Lists of notes: the starter domain `mana new` writes; reshape it into your own."
  use Ash.Domain, extensions: [AshJsonApi.Domain, Mana.Domain]

  resources do
    resource __Name__.Notes.Note
  end

  json_api do
    routes do
      base_route "/notes", __Name__.Notes.Note do
        index :in_list, name: "listNotes"
        post :add, name: "addNote"
        patch :complete, route: "/:id/complete", name: "completeNote"
      end
    end
  end
end

defmodule __Name__.Notes.Note do
  @moduledoc """
  A note on a list. `complete` is a Mana verb: the client is told when it is
  offered (`verbs` on each note) and the server refuses it otherwise.
  """
  use Ash.Resource,
    domain: __Name__.Notes,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource, Mana.Verbs]

  postgres do
    table "notes"
    repo __Name__.Repo
  end

  json_api do
    type "note"
  end

  attributes do
    uuid_primary_key :id
    attribute :list, :string, allow_nil?: false, public?: true, constraints: [max_length: 80]
    attribute :title, :string, allow_nil?: false, public?: true, constraints: [min_length: 1, max_length: 120]
    attribute :done, :boolean, allow_nil?: false, default: false, public?: true
    create_timestamp :inserted_at, type: Contracts.UtcDateTime, public?: true
  end

  verbs do
    verb :add, collection: true, feature: "notes", describe: "Write a note on a list", narrate: "wrote a note"
    verb :complete, when: expr(done == false), feature: "notes", describe: "Mark the note done", narrate: "completed the note"
  end

  actions do
    defaults [:read]

    read :in_list do
      argument :list, :string, allow_nil?: false
      filter expr(list == ^arg(:list))
      prepare build(sort: [inserted_at: :asc])
    end

    create :add do
      accept [:list, :title]
    end

    update :complete do
      accept []
      change set_attribute(:done, true)
    end
  end
end
