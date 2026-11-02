defmodule Mana.VerbsPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Harness, Order}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  defp refused?({:error, error}),
    do:
      Enum.any?(
        Ash.Error.to_error_class(error).errors,
        &match?(%Mana.Error{code: "verb.unavailable"}, &1)
      )

  defp refused?(_), do: false

  test "eight people paying one order at once: one payment lands, the others are refused" do
    order = Ash.create!(Order, %{})
    results = Harness.race(for _ <- 1..8, do: fn -> Ash.update(order, %{}, action: :pay) end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &refused?/1) == 7
    assert Ash.get!(Order, order.id).status == :paid
  end

  test "pay and cancel racing on one order: exactly one lands, every time" do
    for _ <- 1..20 do
      order = Ash.create!(Order, %{})

      [paid, cancelled] =
        Harness.race([
          fn -> Ash.update(order, %{}, action: :pay) end,
          fn -> Ash.update(order, %{}, action: :cancel) end
        ])

      status = Ash.get!(Order, order.id).status

      case {paid, cancelled} do
        {{:ok, _}, refused} ->
          assert refused?(refused)
          assert status == :paid

        {refused, {:ok, _}} ->
          assert refused?(refused)
          assert status == :cancelled
      end
    end
  end

  test "a notice goes out only for a change that committed, after the commit" do
    buyer = Ash.UUID.generate()

    assert {:error, _} =
             Ash.transact(Order, fn ->
               order = Ash.create!(Order, %{buyer_id: buyer})
               Ash.update!(order, %{}, action: :pay)
               {:error, :changed_my_mind}
             end)

    Oban.drain_queue(queue: :default)
    refute_received {:notice, _, _}

    assert {:ok, _} =
             Ash.transact(Order, fn ->
               order = Ash.create!(Order, %{buyer_id: buyer})
               paid = Ash.update!(order, %{}, action: :pay)
               refute_received {:notice, _, _}
               paid
             end)

    Oban.drain_queue(queue: :default)
    assert_received {:notice, "order.paid", false}
    refute_received {:notice, _, _}
  end
end
