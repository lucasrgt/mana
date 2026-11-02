defmodule Mana.HistoryPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Harness, HistoryEntry, Order}

  setup_all do: Harness.start!()
  setup do: Harness.reset!()

  test "an entry that cannot be written refuses the change, and the error reporter hears of it" do
    Application.put_env(:mana_core, :error_reporter, {PostgresTest.Probe, :report})
    on_exit(fn -> Application.delete_env(:mana_core, :error_reporter) end)
    order = Ash.create!(Order, %{title: "fine"})

    assert {:error, error} = Ash.update(order, %{title: "unrecordable"}, action: :rename)
    assert Exception.message(error) =~ "its history entry could not be written"
    assert Ash.get!(Order, order.id).title == "fine"

    assert_received {:reported, %{subject_type: "order", action: "rename"}, message}
    assert message =~ "history_refuses_unrecordable"
    refute_received {:reported, _, _}

    assert [%{outcome: :failed, error: "history.not_recorded", report: "report-1"}] =
             HistoryEntry |> Ash.read!() |> Enum.filter(&(&1.action == "rename"))
  end

  test "an entry's telemetry follows the commit, and never a change that rolled back" do
    :telemetry.attach(
      "history-postgres-test",
      [:mana, :history, :entry],
      &PostgresTest.Probe.entry/4,
      nil
    )

    on_exit(fn -> :telemetry.detach("history-postgres-test") end)

    assert {:error, _} =
             Ash.transact(Order, fn ->
               Ash.create!(Order, %{title: "rolled back"})
               {:error, :changed_my_mind}
             end)

    refute_received {:entry, _, _}

    assert {:ok, _} =
             Ash.transact(Order, fn ->
               order = Ash.create!(Order, %{title: "kept"})
               refute_received {:entry, _, _}
               order
             end)

    assert_received {:entry, "create", false}
    refute_received {:entry, _, _}
  end
end
