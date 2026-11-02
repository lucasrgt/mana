defmodule ManaLint.Check.RawSqlInCalculationTest do
  use Credo.Test.Case

  alias ManaLint.Check.RawSqlInCalculation, as: Check

  test "Repo.query! in calculate/3" do
    """
    defmodule App.Messaging.Preview do
      use Ash.Resource.Calculation

      def calculate(chats, _, _) do
        ids = Enum.map(chats, & &1.id)
        latest = App.Repo.query!("SELECT body FROM chat_messages WHERE chat_id = ANY($1)", [ids]).rows
        Enum.map(ids, &latest[&1])
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "App.Repo.query!"))
  end

  test "a read per record, directly or through a helper" do
    """
    defmodule App.Owner do
      use Ash.Resource.Calculation

      def calculate(records, _, _) do
        Enum.map(records, fn record -> Ash.get!(App.User, record.owner_id).name end) ++
          Enum.map(records, &plan/1)
      end

      defp plan(record), do: Ash.read_one!(App.Plan)
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == ["Ash.get!", "Ash.read_one!"]
    end)
  end

  test "an inline calculation with SQL" do
    """
    defmodule App.Chat do
      use Ash.Resource

      calculations do
        calculate :unread, :integer, fn records, _ ->
          Ecto.Adapters.SQL.query!(App.Repo, "SELECT 1", [])
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Ecto.Adapters.SQL.query!"))
  end

  test "one batched read for all records, and SQL outside calculations, are fine" do
    """
    defmodule App.Owners do
      use Ash.Resource.Calculation
      require Ash.Query

      def calculate(records, _, _) do
        ids = Enum.map(records, & &1.owner_id)
        users = App.User |> Ash.Query.filter(id in ^ids) |> Ash.read!() |> Map.new(&{&1.id, &1})
        Enum.map(records, &users[&1.owner_id].name)
      end
    end

    defmodule App.Report do
      def rows, do: App.Repo.query!("SELECT 1", [])
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
