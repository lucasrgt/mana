defmodule Mana.IncidentPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Harness, Person, Stay, StayDomain}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  defp register(attrs) do
    Person
    |> Ash.Changeset.for_create(:register, Map.put(attrs, :password, "s3cret-#{attrs.phone}"))
    |> Ash.create!()
  end

  # Two people sign up (the host gets verified); the traveler requests a
  # stay of two lines, the host accepts, the traveler pays. The cut falls
  # there, before the traveler cancels.
  defp situation do
    host =
      %{name: "Maria Souza", email: "maria@host.example", phone: "+55 11 98888-0001", role: :host}
      |> register()
      |> Ash.update!(%{}, action: :verify)

    traveler =
      register(%{
        name: "Ana Lima",
        email: "ana@example.com",
        phone: "+55 21 97777-0002",
        role: :traveler
      })

    stay =
      Stay
      |> Ash.Changeset.for_create(
        :request,
        %{
          host_id: host.id,
          scheduled_for: ~U[2026-12-24 15:00:00Z],
          guest_note: "Chego depois das 22h",
          lines: [
            %{name: "Diária", quantity: 3, amount_cents: 25_000},
            %{name: "Limpeza", quantity: 1, amount_cents: 8_000}
          ]
        },
        actor: traveler
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:accept, %{}, actor: host)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:pay, %{}, actor: traveler)
      |> Ash.update!()

    at = DateTime.utc_now()
    stay |> Ash.Changeset.for_update(:cancel, %{}, actor: traveler) |> Ash.update!()
    {host, traveler, stay, at}
  end

  # The booking as a reviewer compares it: its business fields, and each
  # person by role.
  defp projection(stay, roles) do
    %{
      status: stay.status,
      total_cents: stay.total_cents,
      paid: stay.paid,
      scheduled_for: stay.scheduled_for,
      lines: Enum.map(stay.lines, &Map.take(&1, [:name, :quantity, :amount_cents])),
      host: roles[stay.host_id],
      traveler: roles[stay.traveler_id],
      accepted_by: roles[stay.accepted_by_id]
    }
  end

  # A stand-in made from what the fixture kept of the person.
  defp stand_in(_role, %{resource: Person, attributes: attributes}) do
    person =
      Person
      |> Ash.Changeset.for_create(
        :register,
        attributes |> Map.take(~w(name email phone role)) |> Map.put("password", "stand-in")
      )
      |> Ash.create!()

    if attributes["verified"], do: Ash.update!(person, %{}, action: :verify), else: person
  end

  test "a booking's incident holds none of the people's personal values, and opens into the same booking" do
    {host, traveler, stay, at} = situation()
    roles = %{host.id => "host", traveler.id => "traveler"}

    json =
      [StayDomain]
      |> Mana.Incident.export("stay", stay.id, at: at, roles: roles)
      |> Mana.Incident.encode()

    personal =
      [stay.id, stay.guest_note, "s3cret", "hashed:"] ++
        Enum.flat_map([host, traveler], &[&1.id, &1.name, &1.email, &1.phone])

    for value <- personal, do: refute(json =~ value, "#{value} leaked into the incident")

    incident = Jason.decode!(json)
    assert incident["roles"] == ["host", "traveler"]
    assert [%{"ref" => "stay-1", "state" => state, "entries" => entries}] = incident["records"]
    assert Enum.map(entries, & &1["action"]) == ["request", "accept", "pay"]

    assert %{
             "host_id" => "[actor:host]",
             "traveler_id" => "[actor:traveler]",
             "accepted_by_id" => "[actor:host]",
             "status" => "accepted",
             "total_cents" => 83_000,
             "paid" => true,
             "scheduled_for" => "2026-12-24T15:00:00Z",
             "guest_note" => "[personal:guest_note:1]",
             "lines" => [
               %{"name" => "Diária", "quantity" => 3, "amount_cents" => 25_000},
               %{"name" => "Limpeza", "quantity" => 1, "amount_cents" => 8_000}
             ]
           } = state

    assert [
             %{"role" => "host", "type" => "person", "state" => kept_host},
             %{"role" => "traveler", "state" => %{"role" => "traveler", "verified" => false}}
           ] = incident["people"]

    assert %{"role" => "host", "verified" => true, "name" => "[personal:name:" <> _} = kept_host

    path = Path.join(System.tmp_dir!(), "incident-#{System.unique_integer([:positive])}.json")
    File.write!(path, json)
    Harness.reset!()

    assert {:error, %{role: "host", error: :no_person}} =
             Mana.Incident.replay(path, [StayDomain], %{})

    assert {:ok, copy, %{"stay-1" => copy}} =
             Mana.Incident.replay(path, [StayDomain], %{},
               person: &stand_in/2,
               times: :as_recorded
             )

    people = Ash.read!(Person)
    assert length(people) == 2
    copied = Map.new(people, &{&1.id, to_string(&1.role)})
    assert projection(copy, copied) == projection(stay, roles)

    stand_in_host = Enum.find(people, &(&1.role == :host))
    assert {stand_in_host.name, stand_in_host.email} == {"name-1", "email-1@example.invalid"}
    assert stand_in_host.verified
  end
end
