defmodule ExploreDecisionsTest.Rules do
  def exploded?(_record), do: raise("the rule exploded")
end

defmodule ExploreDecisionsTest.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreDecisionsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History.Log]

  history_log do
    subjects([ExploreDecisionsTest.Topic])
  end
end

defmodule ExploreDecisionsTest.Topic do
  @moduledoc false
  # One topic per name: asking again counts on the same record.
  use Ash.Resource,
    domain: ExploreDecisionsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.History, Mana.Reconcile]

  history do
    log(ExploreDecisionsTest.Entry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:name, :string, allow_nil?: false, public?: true)
    attribute(:asks, :integer, default: 1, allow_nil?: false, public?: true)
  end

  identities do
    identity(:name, [:name], pre_check_with: ExploreDecisionsTest.Domain)
  end

  actions do
    defaults([:read])

    create :ask do
      accept([:name])
      upsert?(true)
      upsert_identity(:name)
      upsert_fields([:name])
      change(atomic_update(:asks, expr(asks + 1)))
    end
  end

  verbs do
    verb(:ask, collection: true)
  end

  reconcile do
    desired(:checked, "a rule that cannot be asked",
      scope: expr(true),
      holds: {ExploreDecisionsTest.Rules, :exploded?}
    )
  end
end

defmodule ExploreDecisionsTest.Token do
  @moduledoc false
  # Written, never read back: no read action.
  use Ash.Resource, domain: ExploreDecisionsTest.Domain, data_layer: Ash.DataLayer.Ets

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    create(:issue)
  end
end

defmodule ExploreDecisionsTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ExploreDecisionsTest.Entry)
    resource(ExploreDecisionsTest.Topic)
    resource(ExploreDecisionsTest.Token)
  end
end

defmodule Mana.ExploreDecisionsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Ash.Domain.Info
  alias ExploreDecisionsTest.{Domain, Entry, Token, Topic}

  setup do
    for resource <- Info.resources(Domain), do: Mana.Explore.empty_ets(resource)
    :ok
  end

  defp explore(opts) do
    Mana.Explore.run(
      [Domain],
      Keyword.merge(
        [
          actors: %{ana: nil},
          runs: 3,
          depth: 4,
          seed: 1,
          generators: %{{Topic, :ask} => %{name: "lobby"}},
          shrink: false
        ],
        opts
      )
    )
  end

  test "what exploration cannot use is reported once, never logged per move" do
    {report, log} = with_log(fn -> explore(properties: [:invariant]) end)

    refute log =~ "Mana.Explore"
    assert report.moves > 3
    assert report.unexplored == %{Token => "no primary read action"}

    assert [{what, count}] = Map.to_list(report.skipped)
    assert what =~ "rule checked of ExploreDecisionsTest.Topic: the rule exploded"
    assert count == report.moves

    text = Mana.Explore.format(report)
    assert text =~ "· ExploreDecisionsTest.Token not explored: no primary read action"
    assert text =~ "· skipped #{count}×: rule checked"
  end

  test "history rebuilds a record without landing on the original, which stays as it was" do
    report = explore(properties: [:history_replays], runs: 1, depth: 3)

    assert report.violations == [], Mana.Explore.format(report)
    assert [%{asks: 3} = topic] = Ash.read!(Topic)

    assert Entry |> Ash.read!() |> Enum.map(& &1.subject_id) |> Enum.uniq() == [
             to_string(topic.id)
           ]
  end
end
