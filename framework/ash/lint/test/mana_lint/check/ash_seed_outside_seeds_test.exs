defmodule ManaLint.Check.AshSeedOutsideSeedsTest do
  use Credo.Test.Case

  alias ManaLint.Check.AshSeedOutsideSeeds, as: Check

  @code """
  defmodule App.Promotions do
    def prune(promotion, items) do
      Ash.Seed.update!(promotion, %{items: items})
    end
  end
  """

  test "Ash.Seed in application code" do
    @code
    |> to_source_file("lib/app/promotions.ex")
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Ash.Seed.update!"
      assert issue.message =~ "without an action"
    end)
  end

  test "piped and aliased" do
    """
    defmodule App.Profiles do
      alias Ash.Seed

      def follow(profile, ids), do: profile |> Seed.update!(%{follows: ids})
    end
    """
    |> to_source_file("lib/app/profiles.ex")
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Seed.update!"))
  end

  test "tests, seeds, Moments recipes and support code are fixtures" do
    for path <- [
          "test/app/promotions_test.exs",
          "priv/repo/seeds.exs",
          "lib/app/moments/trips.ex",
          "lib/app/moments.ex",
          "test/support/factory.ex"
        ] do
      @code |> to_source_file(path) |> run_check(Check) |> refute_issues()
    end
  end

  test "a Moments module outside those paths, and configured paths" do
    """
    defmodule App.Moments.Recipes do
      def seed(attrs), do: Ash.Seed.seed!(App.Host, attrs)
    end
    """
    |> to_source_file("lib/app/recipes.ex")
    |> run_check(Check)
    |> refute_issues()

    @code
    |> to_source_file("lib/app/fixtures/promotions.ex")
    |> run_check(Check, allowed_paths: ["lib/app/fixtures/"])
    |> refute_issues()
  end
end
