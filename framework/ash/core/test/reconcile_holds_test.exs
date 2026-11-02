defmodule ReconcileHoldsTest.Rules do
  @moduledoc false
  def charged?(booking), do: not is_nil(booking.charge_id)

  def charge(booking) do
    case Application.get_env(:mana_core, :reconcile_test_repair) do
      :crash -> raise "provider down"
      :refuse -> Ash.update!(booking, %{}, action: :refuse, authorize?: false)
      :drop -> Ash.destroy!(booking, authorize?: false)
      _ -> Ash.update!(booking, %{charge_id: Ash.UUID.generate()}, authorize?: false)
    end
  end
end

defmodule ReconcileHoldsTest.Counted do
  @moduledoc false
  # Tells the test how many bookings each read returned.
  use Ash.Resource.Preparation

  @impl true
  def prepare(query, _opts, _context) do
    Ash.Query.after_action(query, fn _query, records ->
      if pid = Application.get_env(:mana_core, :reconcile_test_pid),
        do: send(pid, {:read, length(records)})

      {:ok, records}
    end)
  end
end

defmodule ReconcileHoldsTest.Booking do
  @moduledoc false
  use Ash.Resource,
    domain: ReconcileHoldsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Reconcile],
    primary_read_warning?: false

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:open, :paid]], public?: true)
    attribute(:charge_id, :uuid, public?: true)
    timestamps()
  end

  actions do
    defaults([:destroy, create: [:status, :charge_id], update: [:charge_id]])

    read :read do
      primary?(true)
      pagination(keyset?: true, required?: false)
      prepare(ReconcileHoldsTest.Counted)
    end

    update :refuse do
      validate(attribute_equals(:status, :open), message: "only open bookings")
    end
  end

  reconcile do
    desired(:paid_has_charge, "a paid booking has a charge",
      scope: expr(status == :paid),
      holds: expr(not is_nil(charge_id)),
      apply: {ReconcileHoldsTest.Rules, :charge}
    )

    desired(:paid_has_charge_fn, "a paid booking has a charge (asked per record)",
      scope: expr(status == :paid),
      holds: {ReconcileHoldsTest.Rules, :charged?}
    )

    desired(:paid_charged_soon, "a paid booking is charged within a minute",
      scope: expr(status == :paid),
      holds: expr(not is_nil(charge_id)),
      within: {1, :minute}
    )
  end
end

defmodule ReconcileHoldsTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ReconcileHoldsTest.Booking)
  end
end

defmodule Mana.ReconcileHoldsTest do
  use ExUnit.Case, async: false

  alias ReconcileHoldsTest.Booking

  setup do
    Mana.Explore.empty_ets(Booking)

    on_exit(fn ->
      Application.delete_env(:mana_core, :reconcile_test_repair)
      Application.delete_env(:mana_core, :error_reporter)
      Application.delete_env(:mana_core, :reconcile_test_pid)
    end)
  end

  defp booking(attrs), do: Ash.create!(Booking, attrs)
  defp rule(report, name), do: Enum.find(report, &(&1.rule == name))

  test "an expression holds is asked in the query: only diverging records are read" do
    for _ <- 1..4, do: booking(%{status: :paid, charge_id: Ash.UUID.generate()})
    missing = booking(%{status: :paid})
    booking(%{status: :open})

    Application.put_env(:mana_core, :reconcile_test_pid, self())
    report = Mana.Reconcile.observe(Booking)
    by_query = rule(report, :paid_has_charge)
    by_function = rule(report, :paid_has_charge_fn)

    assert %{state: :diverging, checked: 5, diverging: [%{id: id, detail: "does not hold"}]} =
             by_query

    assert id == missing.id

    assert Map.take(by_function, [:state, :checked, :diverging]) ==
             Map.take(by_query, [:state, :checked, :diverging])

    # The two expression rules read the one diverging booking each, the
    # function rule all five in scope.
    assert rows_read() == 1 + 1 + 5
  end

  defp rows_read do
    receive do
      {:read, rows} -> rows + rows_read()
    after
      0 -> 0
    end
  end

  test "a timed expression rule diverges once the window passed, and on a record with no clock" do
    paid = booking(%{status: :paid})
    booking(%{status: :paid, charge_id: Ash.UUID.generate()})

    soon = fn now -> Booking |> Mana.Reconcile.observe(now: now) |> rule(:paid_charged_soon) end

    assert %{state: :converged, checked: 2} = soon.(DateTime.add(paid.updated_at, 30, :second))

    assert %{state: :diverging, diverging: [%{id: id, detail: detail}]} =
             soon.(DateTime.add(paid.updated_at, 120, :second))

    assert id == paid.id
    assert detail =~ "longer than 1m: does not hold"
  end

  test "a repair brings the record back; one that removes it settles it too" do
    booking(%{status: :paid})
    assert %{state: :converged, repaired: 1} = repaired()

    Application.put_env(:mana_core, :reconcile_test_repair, :drop)
    booking(%{status: :paid})
    assert %{state: :converged, repaired: 1} = repaired()
  end

  test "a repair the domain refuses blocks quietly; a crashing one is reported" do
    test = self()
    Application.put_env(:mana_core, :reconcile_test_pid, test)
    Application.put_env(:mana_core, :error_reporter, {__MODULE__, :reported})
    stuck = booking(%{status: :paid})

    Application.put_env(:mana_core, :reconcile_test_repair, :refuse)
    assert %{state: :blocked, diverging: [%{id: id}]} = repaired()
    assert id == stuck.id
    refute_received {:reported, _, _}

    Application.put_env(:mana_core, :reconcile_test_repair, :crash)
    assert %{state: :blocked} = repaired()
    assert_received {:reported, %{rule: :paid_has_charge, id: ^id}, %Ash.Error.Unknown{}}
  end

  def reported(metadata, error),
    do:
      send(Application.fetch_env!(:mana_core, :reconcile_test_pid), {:reported, metadata, error})

  defp repaired, do: Booking |> Mana.Reconcile.observe(apply: true) |> rule(:paid_has_charge)
end
