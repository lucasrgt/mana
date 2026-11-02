defmodule Mana.PrivacyPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Booking, Harness, HistoryEntry, Review, Traveler}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  defp values(map) when is_map(map), do: Enum.flat_map(Map.values(map), &values/1)
  defp values(list) when is_list(list), do: Enum.flat_map(list, &values/1)
  defp values(value), do: [value]

  test "erasing a traveler leaves none of their personal values in the history that remains" do
    ana =
      Ash.create!(Traveler, %{
        id: Ash.UUID.generate(),
        name: "Ana Souza",
        email: "ana@example.com"
      })

    actor = %{id: ana.id}

    booking =
      Ash.create!(
        Booking,
        %{traveler_id: ana.id, guest_name: "Ana Souza", phone: "+55 11 9999", nights: 2},
        actor: actor
      )

    Ash.update!(booking, %{phone: "+55 11 8888"}, action: :amend, actor: actor)
    Ash.create!(Review, %{author_id: ana.id, text: "Lovely stay. Ana"}, actor: actor)

    other =
      Ash.create!(Booking, %{traveler_id: Ash.UUID.generate(), guest_name: "Bia", nights: 1})

    Ash.update!(other, %{guest_name: "Bia and Ana Souza"}, action: :amend, actor: actor)

    personal =
      [PostgresTest.Domain]
      |> Mana.Privacy.export(ana.id)
      |> values()
      |> Enum.concat(["+55 11 9999", "Bia and Ana Souza"])
      |> Enum.filter(&is_binary/1)

    assert "ana@example.com" in personal and "Lovely stay. Ana" in personal

    Mana.Privacy.erase([PostgresTest.Domain], ana.id)

    entries = Ash.read!(HistoryEntry)
    assert Enum.any?(entries, &(&1.subject_id == to_string(booking.id)))
    assert Enum.any?(entries, &(&1.subject_id == to_string(other.id)))

    for entry <- entries,
        value <- values([entry.params, entry.before, entry.after]),
        do:
          refute(
            value in personal,
            "#{entry.subject_type}.#{entry.action} kept #{inspect(value)}"
          )

    assert %{"guest_name" => "[erased]", "phone" => "[erased]", "nights" => 2} =
             Enum.find(
               entries,
               &(&1.subject_id == to_string(booking.id) and &1.action == "create")
             ).params

    assert [%{nights: 2, guest_name: "Ana Souza"}] =
             Booking |> Ash.read!() |> Enum.filter(&(&1.traveler_id == ana.id))
  end
end
