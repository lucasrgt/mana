defmodule ManaLint.Check.TableScanCronTest do
  use Credo.Test.Case

  alias ManaLint.Check.TableScanCron, as: Check

  test "a worker that filters a timestamp against now and iterates" do
    """
    defmodule App.Expiration do
      use Oban.Worker, queue: :maintenance
      require Ash.Query

      def perform(_job) do
        now = DateTime.utc_now()

        App.Charge
        |> Ash.Query.filter(status == :pending and created_at <= ^DateTime.add(now, -30, :minute))
        |> Ash.read!(authorize?: false)
        |> Enum.each(&expire/1)
      end

      defp expire(charge), do: Ash.update!(charge, %{}, action: :expire)
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Ash.Query.filter"))
  end

  test "an expression clock in a helper the worker calls" do
    """
    defmodule App.Cleanup do
      use Oban.Worker
      require Ash.Query

      def perform(_), do: sweep()

      defp sweep do
        for old <- App.Export |> Ash.Query.filter(inserted_at < ago(7, :day)) |> Ash.read!() do
          Ash.destroy!(old)
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue()
  end

  test "a worker that acts on its job's record, and timed reads outside workers, are fine" do
    """
    defmodule App.Deliver do
      use Oban.Worker

      def perform(%Oban.Job{args: %{"id" => id}}) do
        App.Notice |> Ash.get!(id) |> App.Mailer.deliver()
      end
    end

    defmodule App.Recent do
      require Ash.Query
      def recent, do: App.Post |> Ash.Query.filter(inserted_at > ago(1, :day)) |> Ash.read!() |> Enum.map(& &1.id)
    end

    defmodule App.Report do
      use Oban.Worker
      require Ash.Query
      def perform(_), do: App.Post |> Ash.Query.filter(status == :draft) |> Ash.read!() |> Enum.each(&IO.inspect/1)
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
