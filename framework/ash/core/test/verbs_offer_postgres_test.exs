defmodule Mana.VerbsOfferPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  import ExUnit.CaptureLog

  alias PostgresTest.{Harness, Order, Repo, VerbsBook, VerbsDomain, VerbsShelf}

  setup_all do
    Harness.start!()
    VerbsDomain.create_tables!(Repo)
    :ok
  end

  setup do
    Harness.reset!()
    VerbsDomain.truncate!(Repo)
  end

  defp shelf(owner, status, books) do
    shelf = Ash.create!(VerbsShelf, %{owner_id: owner.id, status: status}, authorize?: false)
    for _ <- 1..books//1, do: Ash.Seed.seed!(VerbsBook, %{shelf_id: shelf.id})
    shelf
  end

  defp offered(actor) do
    VerbsShelf
    |> Ash.Query.load(:verbs)
    |> Ash.read!(actor: actor)
    |> Map.new(&{&1.id, &1.verbs})
  end

  describe "the verbs a read loads" do
    test "cost one query however many records and verbs" do
      owner = %{id: Ash.UUID.generate()}
      for status <- [:open, :closed], books <- [0, 2], _ <- 1..3, do: shelf(owner, status, books)

      assert queries(fn -> offered(owner) end) == 1
    end

    test "are what each record offers when asked alone" do
      owner = %{id: Ash.UUID.generate()}
      shelves = for status <- [:open, :closed], books <- [0, 2], do: shelf(owner, status, books)

      for actor <- [owner, %{id: Ash.UUID.generate()}, nil] do
        loaded = offered(actor)
        for shelf <- shelves, do: assert(loaded[shelf.id] == Mana.Verbs.offered(shelf, actor))
      end

      open_full = Enum.find(shelves, &(&1.status == :open and &1.id != hd(shelves).id))
      assert offered(owner)[open_full.id] == ["close", "tidy", "claim", "verbs_book.create"]
    end
  end

  describe "a checkpoint's dry run" do
    test "rolls back, reports the notices it would send, and sends and logs nothing" do
      buyer = Ash.UUID.generate()
      order = Ash.create!(Order, %{buyer_id: buyer})
      jobs = Harness.deadline_jobs(order.id)
      flush()

      plan = [%{"resource" => "PostgresTest.Order", "id" => order.id, "verb" => "pay"}]

      log =
        capture_log(fn ->
          assert {:ok, %{outcome: %{status: :done}, notices: [notice], history: [_]}} =
                   Mana.Checkpoint.dry_run(plan, nil)

          assert %{to: ^buyer, template: "order.paid"} = notice
        end)

      assert log == ""
      assert Ash.get!(Order, order.id).status == :open
      assert Harness.deadline_jobs(order.id) == jobs
      refute_received {:broadcast, _, _, _}
      refute_received {:notice, _, _}
      refute_received {:entry, _, _}
    end
  end

  test "a checkpoint's dry run of a plan whose step is refused reports the failure" do
    order = Ash.create!(Order, %{buyer_id: Ash.UUID.generate()})
    step = &%{"resource" => "PostgresTest.Order", "id" => order.id, "verb" => &1}

    assert {:ok, %{outcome: outcome}} =
             Mana.Checkpoint.dry_run([step.("pay"), step.("cancel")], nil)

    assert %{status: :failed, step: 1, error: "verb.unavailable", uncompensated: 1} = outcome
    assert Ash.get!(Order, order.id).status == :open
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp queries(fun) do
    id = make_ref()
    counter = :counters.new(1, [])
    :telemetry.attach(id, [:postgres_test, :repo, :query], &__MODULE__.count/4, {self(), counter})

    try do
      fun.()
      :counters.get(counter, 1)
    after
      :telemetry.detach(id)
    end
  end

  def count(_event, _measurements, _metadata, {pid, counter}) do
    if self() == pid, do: :counters.add(counter, 1, 1)
  end
end
