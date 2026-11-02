defmodule Mana.EntityPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Harness, Order}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  test "a change in a transaction that rolls back is never announced" do
    assert {:error, _} =
             Ash.transact(Order, fn ->
               Ash.create!(Order, %{buyer_id: Ash.UUID.generate()})
               {:error, :changed_my_mind}
             end)

    refute_received {:broadcast, _, _, _}
    assert Ash.read!(Order) == []
  end

  test "a change in a transaction that commits is announced once per topic, after the commit" do
    buyer = Ash.UUID.generate()

    assert {:ok, order} =
             Ash.transact(Order, fn ->
               order = Ash.create!(Order, %{buyer_id: buyer})
               refute_received {:broadcast, _, _, _}
               order
             end)

    assert_received {:broadcast, topic, "changed", false}
    assert topic == "entity:order:#{order.id}"
    assert_received {:broadcast, "entity:order:for:" <> ^buyer, "changed", false}
    refute_received {:broadcast, _, _, _}
  end

  test "a deadline job is inserted with the change, and only once while it waits" do
    assert {:error, _} =
             Ash.transact(Order, fn ->
               Ash.create!(Order, %{title: "rolled back"})
               {:error, :changed_my_mind}
             end)

    assert Harness.deadline_jobs() == 0

    order = Ash.create!(Order, %{title: "a"})
    assert Harness.deadline_jobs(order.id) == 1

    order = Ash.update!(order, %{title: "b"}, action: :rename)
    order = Ash.update!(order, %{title: "c"}, action: :rename)
    assert Harness.deadline_jobs(order.id) == 1

    Ash.update!(order, %{}, action: :pay)
    assert Harness.deadline_jobs() == 1
  end

  test "a deadline whose condition still holds performs its action under the lock" do
    order = Ash.create!(Order, %{})
    assert :ok = Mana.Entity.run_deadline(Order, order.id, "unpaid")
    assert Ash.get!(Order, order.id).status == :expired
    assert :ok = Mana.Entity.run_deadline(Order, order.id, "unpaid")
    assert Ash.get!(Order, order.id).status == :expired
  end

  test "a payment racing the deadline 50 times never ends paid and expired" do
    Application.put_env(:mana_core, :postgres_pay_ms, 20)
    on_exit(fn -> Application.delete_env(:mana_core, :postgres_pay_ms) end)

    outcomes =
      for _ <- 1..50 do
        order = Ash.create!(Order, %{})

        [paid, deadline] =
          Harness.race([
            fn -> Ash.update(order, %{}, action: :pay) end,
            fn -> Mana.Entity.run_deadline(Order, order.id, "unpaid") end
          ])

        assert deadline == :ok
        status = Ash.get!(Order, order.id).status

        case paid do
          {:ok, _} -> assert status == :paid
          {:error, _} -> assert status == :expired
        end

        status
      end

    assert :paid in outcomes
  end
end
