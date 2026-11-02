defmodule Mana.ReplayOrderPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{CatalogDomain, CatalogEntry, Harness, Offering, Venue}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  # A venue is opened first and published last; between the two, an offering
  # of it is added and published, which publishing the venue needs. With
  # `seeded?`, the venue was written outside its actions (no `open` in its
  # history) and renamed through one.
  defp situation(seeded? \\ false) do
    venue =
      if seeded?,
        do:
          Venue
          |> Ash.Seed.seed!(%{name: "Old mill"})
          |> Ash.Changeset.for_update(:rename, %{name: "Mill"})
          |> Ash.update!(),
        else: Ash.create!(Venue, %{name: "Mill"}, action: :open)

    offering =
      Offering
      |> Ash.create!(%{venue_id: venue.id, title: "Tour"}, action: :add)
      |> Ash.update!(%{}, action: :publish)

    venue = Ash.update!(venue, %{}, action: :publish)
    {venue, offering}
  end

  defp projection do
    venues = Map.new(Ash.read!(Venue), &{&1.id, &1.name})

    %{
      venues: Venue |> Ash.read!() |> Enum.map(&{&1.name, &1.status}) |> Enum.sort(),
      offerings:
        Offering
        |> Ash.read!()
        |> Enum.map(&{&1.title, &1.status, venues[&1.venue_id]})
        |> Enum.sort()
    }
  end

  defp export_and_reset(offering) do
    incident = Mana.Incident.export([CatalogDomain], "offering", offering.id)
    expected = projection()
    Harness.reset!()
    {incident, expected}
  end

  test "an incident replays its records' entries in the order they were recorded" do
    {_venue, offering} = situation()
    {incident, expected} = export_and_reset(offering)

    assert [%{"ref" => "venue-1"} = venue, %{"ref" => "offering-1"}] = incident["records"]
    assert Enum.map(venue["entries"], & &1["action"]) == ["open", "publish"]
    refute Map.has_key?(venue, "seed")

    assert {:ok, %Offering{status: :published}, %{"venue-1" => %Venue{status: :published}}} =
             Mana.Incident.replay(incident, [CatalogDomain], %{})

    assert projection() == expected
  end

  test "a record created outside its actions is seeded from its row before its first update" do
    {venue, offering} = situation(true)
    {incident, expected} = export_and_reset(offering)

    assert {:ok, _offering, %{"venue-1" => copy}} =
             Mana.Incident.replay(incident, [CatalogDomain], %{})

    assert copy.id != venue.id
    assert projection() == expected

    assert [%{"ref" => "venue-1"} = kept, %{"ref" => "offering-1"} = other] = incident["records"]
    assert Enum.map(kept["entries"], & &1["action"]) == ["rename", "publish"]
    assert %{"name" => "Old mill", "status" => "draft"} = kept["seed"]
    refute Map.has_key?(kept["seed"], "id")
    refute Map.has_key?(other, "seed")
  end

  test "History.replay refuses a history that starts with an update unless it is given the seed" do
    {venue, _offering} = situation(true)
    entries = Mana.History.export(CatalogEntry, "venue", venue.id)
    assert Mana.History.starts_with_update?(Venue, entries)

    assert {:error, %{at: 0, action: :rename, error: :not_created}} =
             Mana.History.replay(Venue, entries)

    seed = Mana.History.seed_state(Venue, venue.id, Map.take(venue, [:id, :name, :status]))
    assert seed == %{"name" => "Old mill", "status" => "draft"}

    assert {:ok, copy, [:rename]} =
             Mana.History.replay(Venue, Enum.take(entries, 1), seed: seed, times: :as_recorded)

    assert {copy.name, copy.status} == {"Mill", :draft}
    assert copy.id != venue.id
  end

  test "exploring rebuilds a record together with the records that reference it, and a seeded one from its seed" do
    report =
      Mana.Explore.run([CatalogDomain],
        resources: [Venue, Offering],
        setup: fn ->
          situation()
          situation(true)
          %{ana: nil}
        end,
        properties: [:history_replays],
        runs: 1,
        depth: 1,
        seed: 1,
        reset: fn _ -> :ok end,
        shrink: false
      )

    assert report.violations == [], Mana.Explore.format(report)
    refute Enum.any?(Map.keys(report.inconclusive), &match?({:history_not_rebuilt, _, _}, &1))
    assert length(Ash.read!(Venue)) >= 2
    assert Enum.count(Ash.read!(Venue), &(&1.status == :published)) == 2
  end
end
