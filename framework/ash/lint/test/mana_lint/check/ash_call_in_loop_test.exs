defmodule ManaLint.Check.AshCallInLoopTest do
  use Credo.Test.Case

  alias ManaLint.Check.AshCallInLoop, as: Check

  test "a get per record of a read, through a local helper" do
    """
    defmodule App.Expiration do
      def perform(_job) do
        App.Charge
        |> Ash.read!(authorize?: false)
        |> Enum.each(&expire(&1, DateTime.utc_now()))
      end

      defp expire(charge, _now) do
        booking = Ash.get!(App.Booking, charge.booking_id, authorize?: false)
        Ash.update!(booking, %{}, action: :expire)
      end
    end
    """
    |> to_source_file("lib/app/expiration.ex")
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "expire"
      assert issue.message =~ "which calls `Ash.get!`"
      assert issue.message =~ "line 4"
    end)
  end

  test "an update per record in a for over a variable bound to the read" do
    """
    defmodule App.Promotions do
      def prune(query) do
        {:ok, promotions} = Ash.read(query)

        for promotion <- promotions do
          Ash.update!(promotion, %{active: false})
        end
      end
    end
    """
    |> to_source_file("lib/app/promotions.ex")
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Ash.update!"))
  end

  test "a loop over something that is not a read, and bulk actions, are fine" do
    """
    defmodule App.Seeds do
      def create_all(rows), do: Enum.map(rows, &Ash.create!(App.Thing, &1))

      def archive(query) do
        records = Ash.read!(query)
        Ash.bulk_update!(records, :archive, %{})
        Enum.map(records, & &1.id)
      end
    end
    """
    |> to_source_file("lib/app/seeds.ex")
    |> run_check(Check)
    |> refute_issues()
  end

  test "tests and fixtures are allowed" do
    """
    defmodule App.Fixture do
      def touch(q), do: q |> Ash.read!() |> Enum.each(&Ash.update!(&1, %{}))
    end
    """
    |> to_source_file("test/support/fixture.ex")
    |> run_check(Check)
    |> refute_issues()
  end
end
