defmodule VerbsOfferedTest.Card do
  @moduledoc false
  use Ash.Resource,
    domain: VerbsOfferedTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      public?: true
    )
  end

  relationships do
    has_many(:notes, VerbsOfferedTest.Note, destination_attribute: :card_id)
  end

  aggregates do
    count(:note_count, :notes)
  end

  actions do
    defaults([:read, create: [:owner_id, :status]])
    update(:close, change: set_attribute(:status, :closed))
    update(:reopen, change: set_attribute(:status, :open))
    update(:claim)
    update(:escalate)
    update(:tidy)
    update(:archive)

    update :retitle do
      require_atomic?(false)
      argument(:title, :string, allow_nil?: false)

      change(fn changeset, _ ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :status,
          if(String.length(Ash.Changeset.get_argument(changeset, :title)) > 0,
            do: :open,
            else: :closed
          )
        )
      end)
    end
  end

  verbs do
    verb(:close, when: expr(status == :open))
    verb(:reopen, when: expr(status == :closed))
    verb(:claim, when: expr(status == :open and owner_id == ^actor(:id)))
    verb(:escalate)
    verb(:tidy, when: expr(note_count > 1))
    verb(:archive, when: expr(status == :closed), idempotent: true)
    verb(:retitle)
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action([:close, :reopen]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    policy action(:escalate) do
      authorize_if(actor_attribute_equals(:role, :agent))
    end

    policy action([:claim, :tidy, :archive, :retitle]) do
      authorize_if(always())
    end
  end
end

defmodule VerbsOfferedTest.Note do
  @moduledoc false
  use Ash.Resource,
    domain: VerbsOfferedTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)
    attribute(:card_id, :uuid, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:card_id]])
    create(:pin, accept: [:card_id])
  end

  verbs do
    verb(:create,
      collection: true,
      from: {VerbsOfferedTest.Card, :card_id},
      when: expr(status == :open)
    )

    verb(:pin,
      collection: true,
      from: {VerbsOfferedTest.Card, :card_id},
      when: {VerbsOfferedTest.Note, :owner?}
    )
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(actor_present())
    end
  end

  def owner?(card, actor), do: actor != nil and card.owner_id == actor.id
end

defmodule VerbsOfferedTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(VerbsOfferedTest.Card)
    resource(VerbsOfferedTest.Note)
  end
end

defmodule VerbsOfferedTest.Before do
  @moduledoc false
  # `Mana.Verbs.offered/3` as it stood before the offer loaded its conditions
  # with the read: each `when` that memory cannot decide asked of the stored
  # row, record by record.
  def offered(record, actor) do
    resource = record.__struct__

    own =
      for verb <- Mana.Verbs.declared(resource),
          not verb.collection,
          Mana.Verbs.knob_on?(verb, actor),
          holds?(verb, record, resource, actor),
          Mana.Flow not in Spark.extensions(resource) or
            Mana.Flow.may_run?(record, Mana.Verbs.action(verb)),
          can?({record, Mana.Verbs.action(verb)}, actor),
          do: to_string(verb.name)

    related =
      for {child, verb} <- Mana.Verbs.children(resource),
          Mana.Verbs.knob_on?(verb, actor),
          holds?(verb, record, resource, actor),
          can?({child, Mana.Verbs.action(verb), %{elem(verb.from, 1) => record.id}}, actor),
          do: "#{Mana.Entity.type(child)}.#{verb.name}"

    own ++ related
  end

  defp holds?(%{when: nil}, _record, _resource, _actor), do: true

  defp holds?(%{when: {module, function}}, record, _resource, actor),
    do: apply(module, function, [record, actor]) == true

  defp holds?(%{when: expression}, record, resource, actor),
    do: Mana.Verbs.decide(expression, record, resource, actor) == {:ok, true}

  defp can?(subject, actor) do
    Ash.can?(subject, actor, run_queries?: false, maybe_is: false, return_forbidden_error?: false)
  rescue
    _ -> false
  end
end

defmodule Mana.VerbsOfferedTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ash.Domain.Info
  alias VerbsOfferedTest.{Before, Card, Note}

  setup do
    Mana.Explore.empty_ets(Card)
    Mana.Explore.empty_ets(Note)

    owner = %{id: Ash.UUID.generate(), role: :user}
    agent = %{id: Ash.UUID.generate(), role: :agent}
    %{owner: owner, actors: [owner, agent, %{id: Ash.UUID.generate(), role: :user}, nil]}
  end

  defp card(owner, status, notes) do
    card = Ash.create!(Card, %{owner_id: owner.id, status: status}, authorize?: false)
    for _ <- 1..notes//1, do: Ash.Seed.seed!(Note, %{card_id: card.id})
    card
  end

  defp read_offered(actor) do
    Card
    |> Ash.Query.load(:verbs)
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.id, &1.verbs})
  end

  test "the verbs a read loads are exactly what each record offered before, for every actor",
       %{owner: owner, actors: actors} do
    cards =
      for status <- [:open, :closed], notes <- [0, 2], do: card(owner, status, notes)

    capture_log(fn ->
      for actor <- actors do
        loaded = read_offered(actor)

        for card <- cards do
          before = Before.offered(card, actor)
          assert loaded[card.id] == before
          assert Mana.Verbs.offered(card, actor) == before
        end
      end
    end)

    open_with_notes = Enum.find(cards, &(&1.status == :open and &1.id != hd(cards).id))

    capture_log(fn ->
      assert read_offered(owner)[open_with_notes.id] ==
               ["close", "claim", "tidy", "note.create", "note.pin"]
    end)
  end

  test "a record changed in memory is still decided from what it holds" do
    owner = %{id: Ash.UUID.generate(), role: :user}
    open = card(owner, :open, 0)

    capture_log(fn ->
      loaded = Ash.load!(open, :verbs, actor: owner)
      closed = %{loaded | status: :closed}
      assert Mana.Verbs.offered(closed, owner) == Before.offered(closed, owner)
      assert "reopen" in Mana.Verbs.offered(closed, owner)
    end)
  end

  # On ETS the data layer itself reads the notes to count them; on Postgres
  # the count is part of the one query. What the offer added is a read of
  # the card per record and verb its memory could not decide.
  test "reading the verbs of many records reads the records once", %{owner: owner} do
    for _ <- 1..6, do: card(owner, :open, 2)
    assert reads(Card, fn -> read_offered(owner) end) == 1
  end

  test "an action that crashes while the offer is checked is reported, not offered", %{
    owner: owner
  } do
    card = card(owner, :open, 0)
    test = self()
    Application.put_env(:mana_core, :error_reporter, {__MODULE__, :reported})
    Application.put_env(:mana_core, :verbs_test_pid, test)

    on_exit(fn ->
      Application.delete_env(:mana_core, :error_reporter)
      Application.delete_env(:mana_core, :verbs_test_pid)
    end)

    refute "retitle" in Mana.Verbs.offered(card, owner)

    assert_received {:reported, %{verb: :retitle, subject: {Card, :retitle}},
                     %Ash.Error.Unknown{}}

    refute_received {:reported, %{verb: :close}, _}
  end

  def reported(metadata, error),
    do: send(Application.fetch_env!(:mana_core, :verbs_test_pid), {:reported, metadata, error})

  defp reads(resource, fun) do
    id = make_ref()
    domain = Info.short_name(VerbsOfferedTest.Domain)
    counter = :counters.new(1, [])

    :telemetry.attach(id, [:ash, domain, :read, :start], &__MODULE__.count/4, {resource, counter})

    try do
      capture_log(fun)
      :counters.get(counter, 1)
    after
      :telemetry.detach(id)
    end
  end

  def count(_event, _measurements, %{resource: resource}, {resource, counter}),
    do: :counters.add(counter, 1, 1)

  def count(_event, _measurements, _metadata, _config), do: :ok
end
