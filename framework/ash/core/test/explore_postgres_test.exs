defmodule Mana.ExplorePostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Card, Harness, Repo}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  test "exploration on Postgres runs each run in a scope of its own and finds nothing broken" do
    report =
      Mana.Explore.run([PostgresTest.Domain],
        resources: [Card],
        actors: %{ana: nil},
        runs: 4,
        depth: 6,
        seed: 1,
        reset: Mana.Explore.snapshot_reset(Repo, :base, migrations: Harness.migrations()),
        shrink: false
      )

    assert report.violations == []
    assert report.moves > 0
    assert %{never: [], reached: [_ | _]} = report.coverage[Card]
    assert Mana.Snapshot.scopes(Repo) == []
    assert Repo.get_dynamic_repo() == Repo
    assert Ash.read!(Card) == []
  end
end
