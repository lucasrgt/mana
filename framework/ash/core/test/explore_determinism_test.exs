defmodule ExploreDeterminismTest.Broadcast do
  def broadcast(_topic, _event, _payload), do: :ok
end

defmodule ExploreDeterminismTest.Property do
  @moduledoc false
  # Its timestamp has second precision: properties made together tie on it,
  # and ETS answers ties in the order of their random ids.
  use Ash.Resource,
    domain: ExploreDeterminismTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)

    attribute(:kind, :atom,
      constraints: [one_of: [:cabin, :flat, :house, :room]],
      allow_nil?: false,
      public?: true
    )

    attribute(:status, :atom,
      constraints: [one_of: [:draft, :listed]],
      default: :draft,
      public?: true
    )

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])
    update(:list, change: set_attribute(:status, :listed))
  end

  verbs do
    verb(:list, when: expr(status == :draft))
  end
end

defmodule ExploreDeterminismTest.Review do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreDeterminismTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)

    attribute(:about, :atom,
      constraints: [one_of: [:cabin, :flat, :house, :room]],
      public?: true
    )

    create_timestamp(:inserted_at, type: :utc_datetime, public?: true)
  end

  relationships do
    belongs_to(:property, ExploreDeterminismTest.Property, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])

    create :write do
      accept([:property_id])

      change(fn changeset, _ ->
        id = Ash.Changeset.get_attribute(changeset, :property_id)
        property = Ash.get!(ExploreDeterminismTest.Property, id)
        Ash.Changeset.force_change_attribute(changeset, :about, property.kind)
      end)
    end
  end

  verbs do
    verb(:write, collection: true, from: {ExploreDeterminismTest.Property, :property_id})
  end
end

defmodule ExploreDeterminismTest.Hold do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreDeterminismTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.Entity]

  attributes do
    uuid_primary_key(:id)

    attribute(:status, :atom,
      constraints: [one_of: [:pending, :expired]],
      default: :pending,
      public?: true
    )

    timestamps()
  end

  actions do
    defaults([:read])
    update(:touch)
    update(:expire, change: set_attribute(:status, :expired))
  end

  verbs do
    verb(:touch, when: expr(status == :expired))
  end

  entity do
    broadcast(ExploreDeterminismTest.Broadcast)
    deadline(:lapse, action: :expire, when: expr(status == :pending), after: {15, :minute})
  end
end

defmodule ExploreDeterminismTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ExploreDeterminismTest.Property)
    resource(ExploreDeterminismTest.Review)
    resource(ExploreDeterminismTest.Hold)
  end
end

defmodule Mana.ExploreDeterminismTest do
  use ExUnit.Case, async: false

  alias ExploreDeterminismTest.{Domain, Hold, Property, Review}
  alias Mana.Explore.Lock

  # Written as a seed or a fixture writes them: in one go, in the same
  # second.
  defp properties do
    for kind <- [:room, :house, :cabin, :flat],
        do: Ash.Seed.seed!(Property, %{kind: kind, inserted_at: ~U[2026-01-01 10:00:00Z]})

    %{host: nil}
  end

  defp lock do
    [Domain]
    |> Mana.Explore.run(
      resources: [Property, Review],
      setup: &properties/0,
      runs: 1,
      depth: 2,
      seed: 4,
      shrink: false
    )
    |> Lock.build()
    |> Lock.encode()
  end

  test "the same seed writes the same affordances, whatever order the store answers ties in" do
    [first | _] = locks = for _ <- 1..8, do: lock()
    assert Enum.uniq(locks) == [first]
    assert first =~ "status=listed" or first =~ "\"review\""
  end

  test "a deadline falls on the run's clock, not on a stored timestamp" do
    Mana.Explore.run([Domain],
      resources: [Hold],
      setup: fn ->
        Ash.Seed.seed!(Hold, %{updated_at: DateTime.add(DateTime.utc_now(), -2, :hour)})
        %{host: nil}
      end,
      clock: [{1, :minute}],
      properties: [:offer_honest],
      runs: 1,
      depth: 6,
      seed: 1,
      shrink: false
    )

    assert [%{status: :pending}] = Ash.read!(Hold)
  end
end
