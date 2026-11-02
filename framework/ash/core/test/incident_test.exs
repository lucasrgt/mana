defmodule IncidentTest.Entry do
  @moduledoc false
  use Ash.Resource,
    domain: IncidentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History.Log]

  history_log do
    subjects([IncidentTest.Place, IncidentTest.Booking, IncidentTest.Badge])
  end
end

defmodule IncidentTest.Person do
  @moduledoc false
  use Ash.Resource,
    domain: IncidentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource]

  privacy do
    subject(:id)
    export([:email])
    erase(:delete)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:email, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:id, :email]])
  end
end

defmodule IncidentTest.Place do
  @moduledoc false
  use Ash.Resource,
    domain: IncidentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History, Mana.Resource]

  history do
    log(IncidentTest.Entry)
  end

  privacy do
    subject(:owner_id)
    export([:address])
    erase(:keep)
    reason("listings outlive their host")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:address, :string, public?: true)
    attribute(:nightly, :integer, public?: true)
  end

  actions do
    defaults([:read, :destroy])
    create(:list, accept: [:owner_id, :name, :address, :nightly])
    update(:reprice, accept: [:nightly])
  end
end

defmodule IncidentTest.Booking do
  @moduledoc false
  use Ash.Resource,
    domain: IncidentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History, Mana.Resource]

  history do
    log(IncidentTest.Entry)
    redact([:card])
  end

  privacy do
    subject(:traveler_id)
    export([:guest_name, :guest_email])
    erase(:keep)
    reason("tax records")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:nights, :integer, public?: true)
    attribute(:guest_name, :string, public?: true)
    attribute(:guest_email, :string, public?: true)
    attribute(:card, :string, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:requested, :confirmed, :cancelled]],
      default: :requested,
      public?: true
    )
  end

  relationships do
    belongs_to(:place, IncidentTest.Place, public?: true)
    belongs_to(:traveler, IncidentTest.Person, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create(:request,
      accept: [:place_id, :traveler_id, :nights, :guest_name, :guest_email, :card]
    )

    update(:confirm, change: set_attribute(:status, :confirmed))
    update(:cancel, change: set_attribute(:status, :cancelled))

    update :reply_to do
      argument(:address, :string, allow_nil?: false)
      change(set_attribute(:guest_email, arg(:address)))
    end
  end
end

defmodule IncidentTest.Badge do
  @moduledoc false
  # Personal fields of every kind, next to an enum that holds one's text.
  use Ash.Resource,
    domain: IncidentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History, Mana.Resource]

  history do
    log(IncidentTest.Entry)
  end

  privacy do
    subject(:holder_id)
    export([:nickname, :lucky_number, :aliases, :newsletter, :kind])
    personal([:nickname, :lucky_number, :aliases, :newsletter])
    erase(:keep)
    reason("badges are public")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:holder_id, :uuid, public?: true)
    attribute(:nickname, :string, public?: true)
    attribute(:lucky_number, :integer, public?: true)
    attribute(:aliases, {:array, :string}, public?: true)
    attribute(:newsletter, :boolean, public?: true)
    attribute(:kind, :atom, constraints: [one_of: [:host, :guest]], public?: true)
  end

  actions do
    defaults([:read, :destroy])
    create(:issue, accept: [:holder_id, :nickname, :lucky_number, :aliases, :newsletter, :kind])
  end
end

defmodule IncidentTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(IncidentTest.Entry)
    resource(IncidentTest.Person)
    resource(IncidentTest.Place)
    resource(IncidentTest.Booking)
    resource(IncidentTest.Badge)
  end
end

defmodule Mana.IncidentTest do
  use ExUnit.Case, async: false

  alias Ash.Domain.Info
  alias IncidentTest.{Booking, Domain, Entry, Place}

  @host %{id: "3b9f6c1e-8a2d-4f70-9c15-2e6d7a8b9c01"}
  @traveler %{id: "a71c0e52-4d3b-4e9a-8f26-1b5c9d0e7f12"}
  @personal [
    @host.id,
    @traveler.id,
    "Rua das Flores 12",
    "Ana Lima",
    "ana@example.com",
    "ana.lima@example.com",
    "4111 1111 1111 1111"
  ]

  setup do
    empty_store()
    on_exit(fn -> Application.delete_env(:mana_core, :ash_domains) end)
  end

  defp empty_store,
    do: for(resource <- Info.resources(Domain), do: Mana.Explore.empty_ets(resource))

  # A host lists a place and reprices it; a traveler books it and changes
  # the address replies go to; the host confirms; the cut falls there,
  # before the host cancels.
  defp incident do
    place =
      Place
      |> Ash.Changeset.for_create(
        :list,
        %{owner_id: @host.id, name: "Cabin", address: "Rua das Flores 12", nightly: 90},
        actor: @host
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:reprice, %{nightly: 81}, actor: @host)
      |> Ash.update!()

    booking =
      Booking
      |> Ash.Changeset.for_create(
        :request,
        %{
          place_id: place.id,
          traveler_id: @traveler.id,
          nights: 3,
          guest_name: "Ana Lima",
          guest_email: "ana@example.com",
          card: "4111 1111 1111 1111"
        },
        actor: @traveler
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:reply_to, %{address: "ana.lima@example.com"}, actor: @traveler)
      |> Ash.update!()
      |> Ash.Changeset.for_update(:confirm, %{}, actor: @host)
      |> Ash.update!()

    [confirmed | _] =
      Entry |> Ash.Query.sort(at: :desc) |> Ash.read!(authorize?: false)

    booking |> Ash.Changeset.for_update(:cancel, %{}, actor: @host) |> Ash.update!()
    {place, booking, confirmed.at}
  end

  defp card(_ref, :request, params), do: Map.put(params, "card", "4242")
  defp card(_ref, _action, params), do: params

  test "the fixture keeps the situation and no personal value" do
    {place, booking, at} = incident()

    json =
      Domain
      |> Mana.Incident.export("booking", booking.id,
        at: at,
        roles: %{@host.id => "host", @traveler.id => "traveler"}
      )
      |> Mana.Incident.encode()

    for value <- @personal, do: refute(json =~ value, "#{value} leaked")
    refute json =~ place.id
    refute json =~ booking.id

    incident = Jason.decode!(json)
    assert %{"format" => "mana.incident/1", "subject" => "booking-1"} = incident
    assert incident["roles"] == ["host", "traveler"]

    assert [%{"ref" => "place-1"} = listed, %{"ref" => "booking-1"} = booked] =
             incident["records"]

    assert Enum.map(listed["entries"], &{&1["action"], &1["actor_id"]}) ==
             [{"list", "host"}, {"reprice", "host"}]

    assert Enum.map(booked["entries"], & &1["action"]) == ["request", "reply_to", "confirm"]

    assert %{
             "place_id" => "[record:place-1]",
             "traveler_id" => "[actor:traveler]",
             "guest_name" => "[personal:guest_name:1]",
             "guest_email" => "[personal:guest_email:2]",
             "card" => "[redacted]",
             "nights" => 3,
             "status" => "confirmed"
           } = booked["state"]

    # an input under another name is caught by its value
    assert [_, %{"params" => %{"address" => "[personal:guest_email:2]"}}, _] = booked["entries"]
  end

  test "the fixture replays on a fresh store into the same situation" do
    {place, booking, at} = incident()
    path = Path.join(System.tmp_dir!(), "incident-#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Mana.Incident.encode(Mana.Incident.export(Domain, "booking", booking.id, at: at))
    )

    empty_store()
    host = %{id: Ash.UUID.generate()}
    traveler = %{id: Ash.UUID.generate()}

    assert {:error, %{record: "booking-1", action: :request, error: :redacted_input}} =
             Mana.Incident.replay(path, [Domain], %{"person-1" => host, "person-2" => traveler})

    empty_store()

    assert {:ok, copy, %{"place-1" => listed, "booking-1" => copy}} =
             Mana.Incident.replay(path, [Domain], %{"person-1" => host, "person-2" => traveler},
               params: &card/3
             )

    assert {listed.name, listed.nightly, listed.owner_id} == {place.name, 81, host.id}
    assert listed.id != place.id
    assert listed.address == "address-1"

    assert {copy.status, copy.nights, copy.place_id, copy.traveler_id} ==
             {:confirmed, 3, listed.id, traveler.id}

    assert {copy.guest_name, copy.guest_email} ==
             {"guest_name-1", "guest_email-2@example.invalid"}
  end

  test "only personal values are replaced, each by a stand-in of its field's type" do
    badge =
      Ash.create!(
        IncidentTest.Badge,
        %{
          holder_id: @traveler.id,
          nickname: "host",
          lucky_number: 7,
          aliases: [],
          newsletter: true,
          kind: :host
        },
        action: :issue,
        actor: @traveler
      )

    incident = Mana.Incident.export(Domain, "badge", badge.id)

    assert [%{"state" => state}] = incident["records"]

    assert %{
             "nickname" => "[personal:nickname:1]",
             "lucky_number" => "[personal:lucky_number:1]",
             "aliases" => [],
             "newsletter" => true,
             "kind" => "host"
           } = state

    empty_store()

    assert {:ok, copy, _} = Mana.Incident.replay(incident, [Domain], %{"person-1" => @traveler})

    assert {copy.nickname, copy.lucky_number, copy.aliases, copy.newsletter, copy.kind} ==
             {"nickname-1", 1, [], true, :host}
  end

  test "the same history exports the same bytes" do
    {_place, booking, at} = incident()
    once = Mana.Incident.encode(Mana.Incident.export(Domain, "booking", booking.id, at: at))

    assert once ==
             Mana.Incident.encode(Mana.Incident.export(Domain, "booking", booking.id, at: at))

    assert %{"roles" => ["person-1", "person-2"]} = Jason.decode!(once)
  end

  test "mix mana.incident writes the fixture" do
    {_place, booking, at} = incident()
    Application.put_env(:mana_core, :ash_domains, [Domain])
    dir = Path.join(System.tmp_dir!(), "incidents-#{System.unique_integer([:positive])}")
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Mana.Incident.run([
        "booking:#{booking.id}",
        "--at",
        DateTime.to_iso8601(at),
        "--out",
        dir,
        "--role",
        "#{@host.id}=host"
      ])
    after
      Mix.shell(Mix.Shell.IO)
    end

    assert_received {:mix_shell, :info, [message]}
    assert message =~ ~s("host" => ...)
    assert [file] = File.ls!(dir)

    assert %{"roles" => ["host", "person-1"]} =
             dir |> Path.join(file) |> File.read!() |> Jason.decode!()
  end
end
