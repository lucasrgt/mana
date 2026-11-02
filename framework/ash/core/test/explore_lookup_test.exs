defmodule ExploreLookupTest.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreLookupTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History.Log]

  history_log do
    subjects([ExploreLookupTest.Place])
  end
end

defmodule ExploreLookupTest.Profile do
  @moduledoc false
  # A host's onboarding, looked up by the user it belongs to.
  use Ash.Resource, domain: ExploreLookupTest.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, allow_nil?: false, public?: true)
    attribute(:onboarded, :boolean, default: true, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
  end
end

defmodule ExploreLookupTest.Onboarded do
  @moduledoc false
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :owner_id) do
      # Nothing to look up yet (an offer is checked without input).
      nil -> :ok
      owner -> onboarded(owner)
    end
  end

  defp onboarded(owner) do
    if ExploreLookupTest.Profile
       |> Ash.Query.filter(user_id == ^owner and onboarded)
       |> Ash.exists?(authorize?: false),
       do: :ok,
       else: {:error, field: :owner_id, message: "host_onboarding_required"}
  end
end

defmodule ExploreLookupTest.Place do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreLookupTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.History]

  history do
    log(ExploreLookupTest.Entry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:owner_id, :uuid, allow_nil?: false, public?: true)
  end

  relationships do
    has_one :profile, ExploreLookupTest.Profile do
      source_attribute(:owner_id)
      destination_attribute(:user_id)
    end
  end

  actions do
    defaults([:read])

    create :list do
      accept([:name, :owner_id])
      validate(ExploreLookupTest.Onboarded)
    end
  end

  verbs do
    verb(:list, collection: true)
  end
end

defmodule ExploreLookupTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ExploreLookupTest.Entry)
    resource(ExploreLookupTest.Profile)
    resource(ExploreLookupTest.Place)
  end
end

defmodule Mana.ExploreLookupTest do
  use ExUnit.Case, async: false

  alias Ash.Domain.Info
  alias ExploreLookupTest.{Domain, Place, Profile}

  setup do
    for resource <- Info.resources(Domain), do: Mana.Explore.empty_ets(resource)
    :ok
  end

  test "a record rebuilt from its history keeps what it only looks up by another field" do
    owner = Ash.UUID.generate()

    setup = fn ->
      Ash.Seed.seed!(Profile, %{user_id: owner})
      %{host: nil}
    end

    report =
      Mana.Explore.run([Domain],
        setup: setup,
        runs: 1,
        depth: 3,
        seed: 1,
        generators: %{{Place, :list} => %{name: "Camping", owner_id: owner}},
        properties: [:history_replays],
        shrink: false
      )

    assert report.violations == [], Mana.Explore.format(report)
    assert report.moves > 0
    refute Enum.any?(Map.keys(report.inconclusive), &match?({:history_not_rebuilt, _, _}, &1))
    assert [%{user_id: ^owner, onboarded: true}] = Ash.read!(Profile)
  end
end
