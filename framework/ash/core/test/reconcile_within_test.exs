defmodule Mana.ReconcileWithinTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:mana_core, :deadline_inserter, fn _ -> :ok end)
    Ash.DataLayer.Ets.stop(ExploreTest.Hold)
    on_exit(fn -> Application.delete_env(:mana_core, :deadline_inserter) end)
  end

  defp report(now), do: ExploreTest.Hold |> Mana.Reconcile.observe(now: now) |> hd()

  test "a record in scope converges until within has passed, then diverges with its age" do
    hold = Ash.create!(ExploreTest.Hold, %{expires: false}, action: :place)

    assert %{state: :converged} = report(DateTime.add(hold.updated_at, 14 * 60, :second))

    assert %{state: :diverging, diverging: [%{id: id, detail: detail}]} = report(DateTime.add(hold.updated_at, 16 * 60, :second))
    assert id == hold.id
    assert detail =~ "longer than 15m"
  end

  test "a record that left the scope in time is no longer the rule's concern" do
    hold = Ash.create!(ExploreTest.Hold, %{expires: false}, action: :place)
    Ash.update!(hold, %{}, action: :expire)

    assert %{state: :converged, checked: 0} = report(DateTime.add(hold.updated_at, 3600, :second))
  end

  test "a clock per record measures each from its own now" do
    old = Ash.create!(ExploreTest.Hold, %{expires: false}, action: :place)
    young = Ash.create!(ExploreTest.Hold, %{expires: false}, action: :place)
    now = fn record -> if record.id == old.id, do: DateTime.add(old.updated_at, 20 * 60, :second), else: young.updated_at end

    assert %{diverging: [%{id: id}]} = report(now)
    assert id == old.id
  end

  test "a rule needs holds, within, or both" do
    assert_raise Spark.Error.DslError, ~r/needs holds:, within:, or both/, fn ->
      defmodule Pointless do
        use Ash.Resource, domain: nil, validate_domain_inclusion?: false, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Reconcile]

        attributes do
          uuid_primary_key(:id)
        end

        reconcile do
          desired(:nothing, "says nothing", scope: expr(true))
        end
      end
    end
  end
end
