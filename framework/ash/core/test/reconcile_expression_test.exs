defmodule ReconcileExpressionTest.Ledger do
  @moduledoc false
  use Ash.Resource,
    domain: ReconcileExpressionTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)
    attribute(:status, :atom, constraints: [one_of: [:paid, :waived]], public?: true)
    attribute(:charge_id, :uuid, public?: true)
    attribute(:refunded, :boolean, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:status, :charge_id, :refunded]])
  end

  reconcile do
    desired(:not_refunded, "a ledger is not refunded",
      scope: expr(true),
      holds: expr(not refunded)
    )

    desired(:charged_or_waived, "a ledger is charged, or waived",
      scope: expr(true),
      holds: expr(not is_nil(charge_id) or status == :waived)
    )
  end
end

defmodule ReconcileExpressionTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ReconcileExpressionTest.Ledger)
  end
end

defmodule ReconcileExpressionTest.Cases do
  @moduledoc false
  import ExUnit.Assertions

  # A holds both rules; B fails both; C has no `refunded` (so `not refunded`
  # is unknown, not true) and is waived.
  def check(resource) do
    a = Ash.create!(resource, %{status: :paid, charge_id: Ash.UUID.generate(), refunded: false})
    b = Ash.create!(resource, %{status: :paid, refunded: true})
    c = Ash.create!(resource, %{status: :waived})

    report = Map.new(Mana.Reconcile.observe(resource), &{&1.rule, &1})

    assert %{state: :diverging, checked: 3} = report.not_refunded
    assert ids(report.not_refunded) == Enum.sort([b.id, c.id])
    assert %{state: :diverging, checked: 3} = report.charged_or_waived
    assert ids(report.charged_or_waived) == [b.id]
    refute a.id in ids(report.not_refunded)
  end

  defp ids(rule), do: rule.diverging |> Enum.map(& &1.id) |> Enum.sort()
end

defmodule Mana.ReconcileExpressionTest do
  use ExUnit.Case, async: false

  test "a negated and a compound holds diverge only where they fail, on ETS" do
    Mana.Explore.empty_ets(ReconcileExpressionTest.Ledger)
    ReconcileExpressionTest.Cases.check(ReconcileExpressionTest.Ledger)
  end
end

defmodule Mana.ReconcileExpressionPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.Harness

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  test "a negated and a compound holds diverge only where they fail, in the query" do
    ReconcileExpressionTest.Cases.check(PostgresTest.Ledger)
  end
end
