defmodule Mana.ExploreIdentityPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Harness, Note, Rating, Repo, Thread}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  test "an upsert counts on the record it lands on" do
    once = Ash.create!(Thread, %{topic: "lobby"}, action: :ask)
    again = Ash.create!(Thread, %{topic: "lobby"}, action: :ask)
    assert {once.id, once.asks, again.id, again.asks} == {once.id, 1, once.id, 2}
  end

  test "history rebuilds a record beside the one it rebuilds, whatever identity it holds" do
    report =
      Mana.Explore.run([PostgresTest.ChatDomain],
        resources: [Thread, Note, Rating],
        actors: %{ana: nil},
        runs: 6,
        depth: 8,
        seed: 3,
        generators: %{{Thread, :ask} => %{topic: "lobby"}, {Rating, :rate} => %{stars: 4}},
        reset: Mana.Explore.snapshot_reset(Repo, :base, migrations: Harness.migrations()),
        shrink: false
      )

    assert report.violations == [], Mana.Explore.format(report)
    assert MapSet.new([:ask, :post, :rate]) |> MapSet.subset?(reached(report))
    refute Enum.any?(Map.keys(report.inconclusive), &match?({:history_not_rebuilt, _, _}, &1))
  end

  test "a record whose identity names another record is rebuilt too" do
    report =
      Mana.Explore.run([PostgresTest.ChatDomain],
        resources: [Rating],
        setup: fn ->
          Ash.create!(Thread, %{topic: "lobby"}, action: :ask)
          %{ana: nil}
        end,
        runs: 2,
        depth: 2,
        seed: 1,
        generators: %{{Rating, :rate} => %{stars: 4}},
        reset: Mana.Explore.snapshot_reset(Repo, :base, migrations: Harness.migrations()),
        shrink: false
      )

    assert report.violations == [], Mana.Explore.format(report)
    assert :rate in report.coverage[Rating].reached
  end

  test "the check leaves the original as it was" do
    Mana.Explore.run([PostgresTest.ChatDomain],
      resources: [Thread],
      actors: %{ana: nil},
      runs: 1,
      depth: 3,
      seed: 1,
      generators: %{{Thread, :ask} => %{topic: "lobby"}},
      reset: fn _ -> :ok end,
      shrink: false
    )

    assert [%{asks: 3}] = Ash.read!(Thread)
  end

  defp reached(report),
    do: report.coverage |> Map.values() |> Enum.flat_map(& &1.reached) |> MapSet.new()
end
