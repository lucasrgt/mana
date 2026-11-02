defmodule ManaLint.Check.AggregateInElixirTest do
  use Credo.Test.Case

  alias ManaLint.Check.AggregateInElixir, as: Check

  test "an average and a count of mapped fields, reported once per read" do
    """
    defmodule App.Reputation do
      require Ash.Query

      def recompute(user_id) do
        ratings =
          App.Review
          |> Ash.Query.filter(target_id == ^user_id)
          |> Ash.read!(authorize?: false)
          |> Enum.map(& &1.rating)

        average = if ratings == [], do: 0, else: Enum.sum(ratings) / length(ratings)
        Ash.create!(__MODULE__, %{average: average, total: length(ratings)})
      end
    end
    """
    |> to_source_file("lib/app/trust.ex")
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Enum.sum"
      assert issue.message =~ "line 8"
    end)
  end

  test "length of a read, and Enum.max_by over one" do
    """
    defmodule App.Stats do
      def count(q), do: length(Ash.read!(q))
      def latest(q), do: q |> Ash.read!() |> Enum.max_by(& &1.inserted_at)
    end
    """
    |> to_source_file("lib/app/stats.ex")
    |> run_check(Check)
    |> assert_issues(&assert(length(&1) == 2))
  end

  test "records already in hand, other lists, a page and tests are fine" do
    """
    defmodule App.Cards do
      def cards(properties) do
        properties = Ash.load!(properties, [:cover_url])
        {properties, length(properties)}
      end

      def total(items), do: Enum.sum(Enum.map(items, & &1.price))

      def page(query, size) do
        records = query |> Ash.Query.limit(size + 1) |> Ash.read!()
        {Enum.take(records, size), length(records) > size}
      end
    end
    """
    |> to_source_file("lib/app/cards.ex")
    |> run_check(Check)
    |> refute_issues()

    "defmodule T do\n  def t(q), do: length(Ash.read!(q))\nend\n"
    |> to_source_file("test/app/stats_test.exs")
    |> run_check(Check)
    |> refute_issues()
  end
end
