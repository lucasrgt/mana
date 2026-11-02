defmodule ManaLint.Check.DirectRepoOnResourceTest do
  use Credo.Test.Case

  alias ManaLint.Check.DirectRepoOnResource, as: Check

  @resource """
  defmodule App.Partners.Ad do
    use Ash.Resource, data_layer: AshPostgres.DataLayer

    postgres do
      table "partner_ads"
      repo App.Repo
    end
  end
  """

  defp run(code, params \\ []) do
    [
      to_source_file(@resource, "lib/app/partners/ad.ex"),
      to_source_file(code, "lib/app/placement.ex")
    ]
    |> run_check(Check, params)
  end

  test "an Ecto query on a resource's table inside Repo.update_all" do
    """
    defmodule App.Placement do
      import Ecto.Query

      def count(ids) do
        App.Repo.update_all(from(a in "partner_ads", where: a.id in ^ids), inc: [views: 1])
      end
    end
    """
    |> run()
    |> assert_issue(fn issue ->
      assert issue.trigger == "App.Repo.update_all"
      assert issue.message =~ "`partner_ads` table of `App.Partners.Ad`"
    end)
  end

  test "raw SQL naming the table, from a module attribute too" do
    """
    defmodule App.Stats do
      @query "SELECT count(*) FROM partner_ads WHERE status = 'live'"

      def live, do: Ecto.Adapters.SQL.query!(App.Repo, @query, [])

      def opened(id), do: App.Repo.query!("UPDATE partner_ads SET opens = opens + 1 WHERE id = $1", [id])
    end
    """
    |> run()
    |> assert_issues(&assert(length(&1) == 2))
  end

  test "an Ecto query built apart, and the resource as a schema" do
    """
    defmodule App.Report do
      import Ecto.Query
      alias App.Partners.Ad

      def live_query, do: from(a in "partner_ads", where: a.status == "live")

      def all, do: App.Repo.all(Ad)
    end
    """
    |> run()
    |> assert_issues(&assert(length(&1) == 2))
  end

  test "advisory locks, probes and tables no resource owns are left alone" do
    """
    defmodule App.Locks do
      def lock(key), do: App.Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [key])
      def ready?, do: match?({:ok, _}, Ecto.Adapters.SQL.query(App.Repo, "SELECT 1", []))
      def jobs, do: App.Repo.query!("SELECT count(*) FROM oban_jobs", [])
    end
    """
    |> run()
    |> refute_issues()
  end

  test "allowed paths and modules" do
    code = """
    defmodule App.Fixtures do
      def wipe, do: App.Repo.query!("DELETE FROM partner_ads", [])
    end
    """

    [
      to_source_file(@resource, "lib/app/partners/ad.ex"),
      to_source_file(code, "lib/app/moments/ads.ex")
    ]
    |> run_check(Check)
    |> refute_issues()

    code |> run(allowed_modules: ["App.Fixtures"]) |> refute_issues()
  end
end
