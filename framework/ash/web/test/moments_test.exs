defmodule ManaWeb.MomentsTest do
  # The LiveView runner judges the Moments the Flutter runner judges, from the same manifest.
  use ExUnit.Case, async: false

  alias ManaWeb.Moments, as: Runner

  @manifest Moments.Manifest.build(ManaWebTest.Desk)

  def sign_in(conn, account),
    do: Plug.Test.init_test_session(conn, %{"owner_id" => account["id"]})

  defp run(name),
    do:
      Runner.run(@manifest, name,
        endpoint: ManaWebTest.Endpoint,
        recipes: ManaWebTest.Recipes.__recipes__(),
        sign_in: &sign_in/2
      )

  defp statuses(report), do: Map.new(report["checks"], &{&1["name"], &1["status"]})

  test "a journey passes when the screen, its offered verbs and the data all hold" do
    report = run("close-ticket")

    assert report["status"] == "passed"
    assert [%{"name" => "close", "status" => "done"}] = report["steps"]

    assert statuses(report) == %{
             "reopenable" => "passed",
             "closed_on_screen" => "passed",
             "not_closable" => "passed",
             "closed" => "passed"
           }

    assert %{"outcome" => "pass", "acceptanceScore" => 1.0, "protocol" => "avp"} =
             report["verdict"]
  end

  test "a screen that keeps a stale record fails, while the data alone would pass" do
    report = run("close-ticket-on-stale-screen")

    assert report["status"] == "failed"

    assert %{"reopenable" => "failed", "not_closable" => "failed", "closed" => "passed"} =
             statuses(report)

    assert report["verdict"]["outcome"] == "fail"

    assert %{"observed" => [closable]} =
             Enum.find(report["checks"], &(&1["name"] == "not_closable"))

    assert closable =~ ~r/^ticket\.close:/
  end

  test "a child Moment prepares on its parent's launch" do
    report = run("closed-ticket")
    assert report["verdict"]["outcome"] == "pass"
    assert %{"reopenable" => "passed", "not_closable" => "passed"} = statuses(report)
  end

  test "a gesture LiveView does not run yet leaves the verdict inconclusive, never green" do
    report = run("rename-ticket")

    assert report["status"] == "unavailable"
    assert [%{"name" => "title", "status" => "unavailable"}] = report["steps"]
    assert report["verdict"]["outcome"] == "inconclusive"
  end

  test "a Moment only on native platforms does not apply to LiveView" do
    refute Runner.web?(@manifest["moments"]["ticket-on-the-phone"])
    assert run("ticket-on-the-phone")["status"] == "not-applicable"
  end

  test "Moments.Case fails a test on a failed criterion and tells why" do
    report = run("close-ticket-on-stale-screen")

    error = assert_raise ExUnit.AssertionError, fn -> Runner.Case.assert_pass(report) end
    assert error.message =~ "moment:close-ticket-on-stale-screen is fail"
    assert error.message =~ "fail reopenable"
    assert Runner.Case.assert_pass(run("close-ticket"))["status"] == "passed"
  end
end

defmodule ManaWeb.MomentsCaseTest do
  use ExUnit.Case, async: false

  # Every web Moment of the manifest becomes a test; only the ones expected to pass are kept here.
  use ManaWeb.Moments.Case,
    manifest:
      update_in(
        Moments.Manifest.build(ManaWebTest.Desk)["moments"],
        &Map.take(&1, ["close-ticket", "closed-ticket", "ticket-on-the-phone"])
      ),
    endpoint: ManaWebTest.Endpoint,
    recipes: ManaWebTest.Recipes.__recipes__(),
    sign_in: &ManaWeb.MomentsTest.sign_in/2

  test "the generated tests are the web Moments" do
    names = for {name, _arity} <- __MODULE__.__info__(:functions), do: to_string(name)
    assert Enum.any?(names, &(&1 =~ "moment:close-ticket "))
    assert Enum.any?(names, &(&1 =~ "moment:closed-ticket "))
    refute Enum.any?(names, &(&1 =~ "ticket-on-the-phone"))
  end
end
