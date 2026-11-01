defmodule ExploreTest.Broadcast do
  def broadcast(_topic, _event, _payload), do: :ok
end

defmodule ExploreTest.Rules do
  def has_reason?(card), do: if(card.reason, do: true, else: {false, "closed without a reason"})
end

defmodule ExploreTest.Card do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)
    attribute(:status, :atom, constraints: [one_of: [:draft, :open, :closed]], default: :draft, public?: true)
    attribute(:archived, :boolean, default: false, public?: true)
  end

  actions do
    defaults([:read])
    create(:draft, accept: [:title])
    update(:publish, change: set_attribute(:status, :open))
    update(:close, change: set_attribute(:status, :closed))
    update(:reopen, change: set_attribute(:status, :open))
    update(:archive, change: set_attribute(:archived, true))
  end

  verbs do
    verb(:draft, collection: true)
    verb(:publish, when: expr(status == :draft))
    verb(:close, when: expr(status == :open), inverse: :reopen)
    verb(:reopen, when: expr(status == :closed), inverse: :close)
    verb(:archive, when: expr(status == :closed), idempotent: true)
  end
end

defmodule ExploreTest.Crashy do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:open, :done]], default: :open, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)

    update :boom do
      require_atomic?(false)
      change(fn changeset, _context -> Ash.Changeset.after_action(changeset, fn _, _ -> raise "boom" end) end)
    end
  end

  verbs do
    verb(:start, collection: true)
    verb(:boom, when: expr(status == :open))
  end
end

# Two verbs share one action; the server checks the first one's `when` only.
defmodule ExploreTest.Shared do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:draft, :live, :archived]], default: :draft, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)
    update(:set_live, change: set_attribute(:status, :live))
    update(:retire, change: set_attribute(:status, :archived))
  end

  verbs do
    verb(:start, collection: true)
    verb(:publish, action: :set_live, when: expr(status == :draft))
    verb(:republish, action: :set_live, when: expr(status == :archived))
    verb(:retire, when: expr(status == :live))
  end
end

defmodule ExploreTest.Counter do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:count, :integer, default: 0, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)

    update :bump do
      require_atomic?(false)
      change(fn changeset, _ -> Ash.Changeset.force_change_attribute(changeset, :count, changeset.data.count + 1) end)
    end
  end

  verbs do
    verb(:start, collection: true)
    verb(:bump, idempotent: true)
  end
end

defmodule ExploreTest.Lamp do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:visible, :boolean, default: true, public?: true)
    attribute(:color, :atom, constraints: [one_of: [:white, :red]], default: :white, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)
    update :hide do
      change(set_attribute(:visible, false))
      change(set_attribute(:color, :red))
    end

    update(:show, change: set_attribute(:visible, true))
  end

  verbs do
    verb(:start, collection: true)
    verb(:hide, when: expr(visible == true), inverse: :show)
    verb(:show, when: expr(visible == false), inverse: :hide)
  end
end

defmodule ExploreTest.Ticket do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:open, :closed]], default: :open, public?: true)
    attribute(:reason, :string, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)
    update(:close, change: set_attribute(:status, :closed))
  end

  verbs do
    verb(:start, collection: true)
    verb(:close, when: expr(status == :open))
  end

  reconcile do
    desired(:closed_has_reason, "every closed ticket says why", scope: expr(status == :closed), holds: {ExploreTest.Rules, :has_reason?})
  end
end

defmodule ExploreTest.Hold do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.Reconcile, Mana.Entity]

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:pending, :paid, :expired]], default: :pending, public?: true)
    attribute(:expires, :boolean, default: true, public?: true)
    timestamps()
  end

  actions do
    defaults([:read])
    create(:place, accept: [:expires])
    update(:pay, change: set_attribute(:status, :paid))
    update(:expire, change: set_attribute(:status, :expired))
  end

  verbs do
    verb(:place, collection: true)
    verb(:pay, when: expr(status == :pending and expires == false), external: "stripe")
  end

  reconcile do
    desired(:pending_resolves, "a pending hold is paid or expires within 15 minutes", scope: expr(status == :pending), within: {15, :minute})
  end

  entity do
    broadcast(ExploreTest.Broadcast)
    deadline(:lapse, action: :expire, when: expr(status == :pending and expires == true), after: {15, :minute})
  end
end

defmodule ExploreTest.Onboarding do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.Flow]

  attributes do
    uuid_primary_key(:id)
    attribute(:stage, :atom, constraints: [one_of: [:terms, :details, :done]], default: :terms, public?: true)
    attribute(:ready, :boolean, default: false, public?: true)
  end

  actions do
    defaults([:read])
    create(:begin)

    update :accept_terms do
      require_atomic?(false)
    end

    update :save_details do
      require_atomic?(false)
    end
  end

  verbs do
    verb(:begin, collection: true)
    verb(:accept_terms)
    # Never offered: the details step can never be done.
    verb(:save_details, when: expr(ready == true))
  end

  flow do
    cursor(:stage)
    step(:terms, action: :accept_terms)
    step(:details, action: :save_details)
    done(:done)
  end
end

defmodule ExploreTest.Rewind do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.Flow]

  attributes do
    uuid_primary_key(:id)
    attribute(:stage, :atom, constraints: [one_of: [:terms, :details, :done]], default: :terms, public?: true)
  end

  actions do
    defaults([:read])
    create(:begin)

    update :accept_terms do
      require_atomic?(false)
    end

    update :save_details do
      require_atomic?(false)
    end

    update(:restart, change: set_attribute(:stage, :terms))
  end

  verbs do
    verb(:begin, collection: true)
    verb(:accept_terms)
    verb(:save_details)
    verb(:restart, when: expr(stage == :details))
  end

  flow do
    cursor(:stage)
    step(:terms, action: :accept_terms)
    step(:details, action: :save_details)
    done(:done)
  end
end

defmodule ExploreTest.Entry do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.History.Log]

  history_log do
    subjects([ExploreTest.Memo, ExploreTest.Serial])
  end
end

defmodule ExploreTest.Memo do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.History]

  history do
    log(ExploreTest.Entry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:body, :string, public?: true)
    attribute(:pinned, :boolean, default: false, public?: true)
  end

  actions do
    defaults([:read, :destroy])
    create(:write, accept: [:body])
    update(:pin, change: set_attribute(:pinned, true))
  end

  verbs do
    verb(:write, collection: true)
    verb(:pin, when: expr(pinned == false))
  end
end

defmodule ExploreTest.Serial do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.History]

  history do
    log(ExploreTest.Entry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:number, :integer, public?: true)
  end

  actions do
    defaults([:read, :destroy])

    create :issue do
      change(fn changeset, _ -> Ash.Changeset.force_change_attribute(changeset, :number, System.unique_integer([:positive])) end)
    end
  end

  verbs do
    verb(:issue, collection: true)
  end
end

defmodule ExploreTest.Shelf do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:open, :boolean, default: true, public?: true)
  end

  actions do
    defaults([:read, create: [:open]])
  end

  verbs do
  end
end

defmodule ExploreTest.Book do
  @moduledoc false
  use Ash.Resource, domain: ExploreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:shelf_id, :uuid, public?: true)
    attribute(:lent, :boolean, default: false, public?: true)
  end

  relationships do
    belongs_to(:shelf, ExploreTest.Shelf, define_attribute?: false, source_attribute: :shelf_id)
  end

  actions do
    defaults([:read])
    create(:shelve, accept: [:shelf_id])
    update(:lend, change: set_attribute(:lent, true))
  end

  verbs do
    verb(:shelve, collection: true, from: {ExploreTest.Shelf, :shelf_id}, when: expr(open == true))
    verb(:lend, when: expr(lent == false))
  end
end

defmodule ExploreTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ExploreTest.Card)
    resource(ExploreTest.Crashy)
    resource(ExploreTest.Shared)
    resource(ExploreTest.Counter)
    resource(ExploreTest.Lamp)
    resource(ExploreTest.Ticket)
    resource(ExploreTest.Hold)
    resource(ExploreTest.Onboarding)
    resource(ExploreTest.Rewind)
    resource(ExploreTest.Entry)
    resource(ExploreTest.Memo)
    resource(ExploreTest.Serial)
    resource(ExploreTest.Shelf)
    resource(ExploreTest.Book)
  end
end

defmodule Mana.ExploreTest do
  use ExUnit.Case, async: false

  @domains [ExploreTest.Domain]
  @actors %{ana: %{id: "0d4c7a52-5d2f-4a8e-9f61-3b2a1c0e9a01"}, bia: %{id: "6f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0"}}

  defp explore(resource, opts \\ []), do: Mana.Explore.run(@domains, [resources: [resource], actors: @actors, runs: 30, depth: 8, seed: 7] ++ opts)

  defp properties(report), do: Enum.map(report.violations, & &1.property)

  test "a resource that keeps its promises breaks nothing and reaches every verb" do
    report = explore(ExploreTest.Card, runs: 40, depth: 10)

    assert report.violations == [], Mana.Explore.format(report)
    assert report.coverage[ExploreTest.Card].never == []
    assert report.moves > 0
    assert Mana.Explore.verdict("cards", report)["outcome"] == "pass"
  end

  test "a child is started from a parent that is not explored itself" do
    setup = fn ->
      Ash.create!(ExploreTest.Shelf, %{open: true})
      @actors
    end

    report = Mana.Explore.run(@domains, resources: [ExploreTest.Book], setup: setup, runs: 10, depth: 4, seed: 3)
    assert report.violations == [], Mana.Explore.format(report)
    assert report.coverage[ExploreTest.Book].reached == [:lend, :shelve]
  end

  test "the affordance graph names each shape and what each actor was offered there" do
    report = explore(ExploreTest.Card, runs: 20)
    open = report.affordances[{"card", "archived=false,status=open"}]

    assert open.seen > 0
    assert Map.keys(open.ana) == ["close"]
    assert Enum.any?(report.transitions, &(&1.from == "archived=false,status=draft" and &1.verb == "publish" and &1.to == "archived=false,status=open"))
  end

  test "an offered verb that crashes breaks offer_honest" do
    report = explore(ExploreTest.Crashy)
    assert [%{property: :offer_honest, verb: :boom, detail: detail} = violation] = report.violations
    assert detail =~ "crashed"
    assert Enum.map(violation.trace, & &1.kind) == [:start, :verb]
  end

  test "a verb the record does not offer but the server performs breaks refusal_enforced" do
    report = explore(ExploreTest.Shared, probe: 0.6, runs: 40)
    assert :refusal_enforced in properties(report)
    violation = Enum.find(report.violations, &(&1.property == :refusal_enforced))
    assert violation.verb in [:publish, :republish]
  end

  test "an idempotent verb that changes the record again breaks idempotent" do
    report = explore(ExploreTest.Counter)
    assert [%{property: :idempotent, verb: :bump, detail: "a second time changed count"}] = report.violations
  end

  test "an inverse that leaves a field changed breaks inverse_restores, shrunk to the moves that matter" do
    report = explore(ExploreTest.Lamp, runs: 40)
    assert [%{property: :inverse_restores, verb: :hide, detail: detail, trace: trace}] = report.violations
    assert detail =~ "color"
    assert [%{kind: :start}, %{kind: :verb, verb: :hide, then_inverse: true}] = Enum.map(trace, &Map.take(&1, [:kind, :verb, :then_inverse]))
  end

  test "a reconcile rule broken in a reachable state is an invariant violation" do
    report = explore(ExploreTest.Ticket)
    assert [%{property: :invariant, verb: :closed_has_reason, detail: detail}] = report.violations
    assert detail =~ "closed without a reason"
  end

  test "a timed rule with no deadline to honour it breaks eventually once the clock moves" do
    report = explore(ExploreTest.Hold, runs: 30, depth: 6)
    assert [%{property: :eventually, verb: :pending_resolves, trace: trace}] = report.violations
    assert Enum.any?(trace, &(&1.kind == :clock))
    assert List.last(trace).kind == :clock
  end

  test "a deadline that honours the rule keeps it converged; external verbs are never performed" do
    report = explore(ExploreTest.Hold, runs: 30, depth: 6, generators: %{{ExploreTest.Hold, :place} => %{expires: true}})
    assert report.violations == [], Mana.Explore.format(report)
    assert report.coverage[ExploreTest.Hold].skipped == [:pay]
  end

  test "a flow step no one is ever offered is a deadlock" do
    report = explore(ExploreTest.Onboarding)
    assert [%{property: :flow_deadlock, detail: detail}] = report.violations
    assert detail =~ "details"
  end

  test "a verb that sends the flow cursor back breaks flow_monotonic" do
    report = explore(ExploreTest.Rewind, runs: 40)
    assert [%{property: :flow_monotonic, verb: :restart}] = report.violations
  end

  test "history that replays to the same record passes; one that does not is reported" do
    assert explore(ExploreTest.Memo).violations == []

    assert [%{property: :history_replays, detail: detail}] = explore(ExploreTest.Serial).violations
    assert detail =~ "number"
  end

  test "runs are deterministic for a seed" do
    a = explore(ExploreTest.Card, runs: 10)
    b = explore(ExploreTest.Card, runs: 10)
    assert a.affordances == b.affordances
    assert a.moves == b.moves
  end

  test "a saved trace rebuilds its situation, and replays to the same violation" do
    [violation] = explore(ExploreTest.Ticket).violations
    dir = Path.join(System.tmp_dir!(), "explore-#{System.unique_integer([:positive])}")
    path = Mana.Explore.save(violation, dir)

    assert %{"property" => "invariant", "moves" => [_ | _]} = Jason.decode!(File.read!(path))

    for resource <- Ash.Domain.Info.resources(ExploreTest.Domain), do: Mana.Explore.empty_ets(resource)
    records = Mana.Explore.replay_file(path, @domains, @actors)
    assert Enum.any?(Map.values(records), &match?(%ExploreTest.Ticket{status: :closed}, &1))

    assert %{property: :invariant} = Mana.Explore.replay(@domains, violation.trace, resources: [ExploreTest.Ticket], actors: @actors, seed: 7)
  end

  test "format reads as a person would" do
    text = Mana.Explore.format(explore(ExploreTest.Counter))
    assert text =~ "✗ idempotent ExploreTest.Counter.bump"
    assert text =~ "start → "
  end

  describe "affordance lock" do
    test "is stable for a seed and names what each actor is offered in each shape" do
      lock = ExploreTest.Card |> explore(runs: 20) |> Mana.Explore.Lock.build()
      again = ExploreTest.Card |> explore(runs: 20) |> Mana.Explore.Lock.build()

      assert Mana.Explore.Lock.encode(lock) == Mana.Explore.Lock.encode(again)
      assert lock["resources"]["card"]["archived=false,status=open"]["ana"] == ["close"]
      assert Mana.Explore.Lock.diff(lock, lock |> Mana.Explore.Lock.encode() |> Jason.decode!()) == []
    end

    test "a changed offer reads as a sentence" do
      old = %{"resources" => %{"booking" => %{"status=paid" => %{"host" => ["cancel", "refund"]}, "status=gone" => %{}}}}
      new = %{"resources" => %{"booking" => %{"status=paid" => %{"host" => ["refund", "rate"]}, "status=new" => %{}}}}

      assert Mana.Explore.Lock.diff(old, new) == [
               "booking when status=gone is no longer reached",
               "booking when status=new is newly reached",
               "`cancel` is no longer offered to host on booking when status=paid",
               "`rate` is now offered to host on booking when status=paid"
             ]
    end
  end
end
