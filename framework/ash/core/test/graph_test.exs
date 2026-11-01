defmodule GraphTest.KnobValue do
  @moduledoc false
  use Ash.Resource, domain: GraphTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Knobs.Store]
end

defmodule GraphTest.Knobs do
  @moduledoc false
  use Mana.Knobs, store: GraphTest.KnobValue
  knob(:coupons, :boolean, default: false, enables: "checkout/coupon", describe: "Coupons")
  knob(:tipping, :boolean, default: false)
end

defmodule GraphTest.Booking do
  @moduledoc false
  use Ash.Resource, domain: GraphTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.Views, Mana.Entity]

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:open, :paid, :cancelled, :expired]], default: :open, public?: true)
  end

  actions do
    defaults([:read])
    create(:book)
    update(:pay)
    update(:apply_coupon)
    update(:tip)
    update(:cancel)
    update(:reopen)
    update(:expire)
    update(:archive)
  end

  verbs do
    verb(:book, collection: true, feature: "checkout")
    verb(:pay, when: expr(status == :open), risk: :money, feature: "checkout/pay")
    verb(:apply_coupon, feature: "checkout/coupon")
    verb(:tip, knob: :tipping)
    verb(:cancel, inverse: :reopen)
    verb(:reopen, inverse: :cancel)
    verb(:expire)
    verb(:archive)
  end

  views do
    view(:card, fields: [:status, :verbs])
  end

  entity do
    broadcast(ExploreTest.Broadcast)
    deadline(:lapse, action: :expire, when: expr(status == :open), after: {15, :minute})
  end
end

defmodule GraphTest.Note do
  @moduledoc false
  use Ash.Resource, domain: GraphTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs, Mana.Views]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
    read(:mine)
    update(:pin)
  end

  verbs do
    verb(:pin)
  end

  views do
    view(:row, fields: [:verbs], entry: :mine)
  end
end

defmodule GraphTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(GraphTest.KnobValue)
    resource(GraphTest.Booking)
    resource(GraphTest.Note)
  end
end

defmodule Mana.GraphTest do
  use ExUnit.Case, async: true

  setup_all do
    path = Path.join(System.tmp_dir!(), "graph-manifest-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{"moments" => %{
      "checkout-paid" => %{"steps" => [%{"kind" => "tap", "target" => "verb:booking.pay", "verb" => "booking.pay"}], "checks" => []},
      "cancel-shows" => %{"steps" => [%{"kind" => "tap", "target" => "verb:booking.cancel:abc"}], "checks" => [%{"kind" => "offered", "verb" => "booking.reopen"}]}
    }}))

    graph = Mana.Graph.build([GraphTest.Domain], manifests: [path], knobs: GraphTest.Knobs, screens: %{"booking.apply_coupon" => ["lib/checkout/view.dart"]})
    {:ok, graph: graph}
  end

  test "verbs no Moment names", %{graph: graph} do
    assert Mana.Graph.query(graph, :verbs_without_moment) == ["booking.apply_coupon", "booking.archive", "booking.book", "booking.expire", "booking.tip", "note.pin"]
  end

  test "which Moments prove a verb, by step, check or verb key", %{graph: graph} do
    assert Mana.Graph.query(graph, {:proves, "booking.pay"}) == ["checkout-paid"]
    assert Mana.Graph.query(graph, {:proves, "booking.cancel"}) == ["cancel-shows"]
    assert Mana.Graph.query(graph, {:proves, "booking.reopen"}) == ["cancel-shows"]
  end

  test "what a knob guards: its own verbs and every verb of the features it enables", %{graph: graph} do
    assert Mana.Graph.query(graph, {:knob, "tipping"}) == %{guards: ["booking.tip"], features: []}
    assert Mana.Graph.query(graph, {:knob, "coupons"}) == %{guards: ["booking.apply_coupon"], features: ["checkout/coupon"]}
  end

  test "dead verbs: reached by no Moment, screen, agent entry, deadline or flow", %{graph: graph} do
    # pin is reachable by agents through the note entry; expire by its deadline
    assert Mana.Graph.query(graph, :dead_verbs) == ["booking.archive", "booking.book", "booking.tip"]
  end

  test "everything around one verb, and stable JSON", %{graph: graph} do
    around = Mana.Graph.query(graph, {:verb, "booking.cancel"})
    assert %{from: "moment:cancel-shows", relation: :proves} in around
    assert %{relation: :inverse, to: "verb:booking.reopen"} in around

    json = Mana.Graph.to_json(graph)
    assert json == Mana.Graph.to_json(graph)
    assert Enum.any?(json["nodes"], &(&1["id"] == "verb:booking.pay" and &1["risk"] == "money"))
  end
end
