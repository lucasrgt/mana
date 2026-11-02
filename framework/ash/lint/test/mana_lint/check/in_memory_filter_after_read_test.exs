defmodule ManaLint.Check.InMemoryFilterAfterReadTest do
  use Credo.Test.Case

  alias ManaLint.Check.InMemoryFilterAfterRead, as: Check

  test "a field comparison through a function of the module" do
    """
    defmodule App.Discovery do
      def accepts_vehicle?(_, nil), do: true
      def accepts_vehicle?(%{accepted_vehicles: []}, _), do: true
      def accepts_vehicle?(%{accepted_vehicles: accepted}, vehicle), do: vehicle in accepted

      def nearby(query, vehicle) do
        query
        |> Ash.read!(authorize?: false)
        |> rank()
        |> Enum.filter(&accepts_vehicle?(&1, vehicle))
      end

      defp rank(properties), do: Enum.sort_by(properties, & &1.rank)
    end
    """
    |> to_source_file("lib/app/discovery.ex")
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Enum.filter"
      assert issue.message =~ "field comparison"
    end)
  end

  test "captures and fns comparing fields, across modules" do
    [
      """
      defmodule App.Rules do
        def live?(ad), do: ad.status == :live and not is_nil(ad.business_id)
      end
      """,
      """
      defmodule App.Ads do
        def live(q), do: q |> Ash.read!() |> Enum.filter(&App.Rules.live?/1)
        def by_city(q, city), do: Enum.reject(Ash.read!(q), fn ad -> ad.city != city end)
        def first_open(q), do: Enum.find(Ash.read!(q), & &1.open)
      end
      """
    ]
    |> to_source_files()
    |> run_check(Check)
    |> assert_issues(&assert(length(&1) == 3))
  end

  test "non-trivial predicates only with non_trivial: true" do
    code = """
    defmodule App.Map do
      def points(q, filters), do: q |> Ash.read!() |> Enum.filter(&matches?(filters, &1))
      defp matches?(filters, point), do: String.contains?(point.name, filters.text)
    end
    """

    code |> to_source_file("lib/app/map.ex") |> run_check(Check) |> refute_issues()

    code
    |> to_source_file("lib/app/map.ex")
    |> run_check(Check, non_trivial: true)
    |> assert_issue(&assert(&1.message =~ "If the rule can be"))
  end

  test "filtering lists that are not reads is fine" do
    """
    defmodule App.Lists do
      def live(ads), do: Enum.filter(ads, &(&1.status == :live))
      def loaded(ads), do: ads |> Ash.load!([:x]) |> Enum.filter(& &1.x)
    end
    """
    |> to_source_file("lib/app/lists.ex")
    |> run_check(Check)
    |> refute_issues()
  end
end
