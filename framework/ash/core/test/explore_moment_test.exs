defmodule ExploreMomentTest.Rules do
  def has_reason?(ticket),
    do: if(ticket.reason, do: true, else: {false, "closed without a reason"})
end

# The seeded bug: `close` forgets the reason until the app is fixed.
defmodule ExploreMomentTest.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreMomentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      public?: true
    )

    attribute(:reason, :string, public?: true)
  end

  actions do
    defaults([:read])
    create(:start)

    update :close do
      require_atomic?(false)
      change(set_attribute(:status, :closed))

      change(fn changeset, _ ->
        if Application.get_env(:mana_core, :explore_moment_fixed, false),
          do: Ash.Changeset.force_change_attribute(changeset, :reason, "resolved"),
          else: changeset
      end)
    end
  end

  verbs do
    verb(:start, collection: true)
    verb(:close, when: expr(status == :open))
  end

  reconcile do
    desired(:closed_has_reason, "every closed ticket says why",
      scope: expr(status == :closed),
      holds: {ExploreMomentTest.Rules, :has_reason?}
    )
  end
end

# Its rule is broken from the start, outside what the exploration explored.
defmodule ExploreMomentTest.Elsewhere do
  @moduledoc false
  use Ash.Resource,
    domain: ExploreMomentTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)
  end

  actions do
    defaults([:read])
    create(:start)
  end

  verbs do
    verb(:start, collection: true)
  end

  reconcile do
    desired(:never, "never holds",
      scope: expr(not is_nil(id)),
      holds: {ExploreMomentTest.Elsewhere, :never}
    )
  end

  def never(_record), do: {false, "never holds"}
end

defmodule ExploreMomentTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(ExploreMomentTest.Ticket)
    resource(ExploreMomentTest.Elsewhere)
  end
end

defmodule ExploreMomentTest.Explore do
  def options,
    do: [
      domains: [ExploreMomentTest.Domain],
      resources: [ExploreMomentTest.Ticket],
      setup: &actors/0,
      runs: 10,
      depth: 4
    ]

  def actors do
    Ash.create!(ExploreMomentTest.Elsewhere, %{}, action: :start)
    %{ana: nil}
  end
end

defmodule Mana.ExploreMomentTest do
  use ExUnit.Case, async: false

  alias ExploreMomentTest.{Domain, Elsewhere, Explore, Ticket}

  @domains [Domain]

  setup do
    Application.delete_env(:mana_core, :explore_moment_fixed)
    dir = Path.join(System.tmp_dir!(), "explore-moment-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.delete_env(:mana_core, :explore_moment_fixed)
      Application.delete_env(:mana_core, :explore)
      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  defp found do
    [violation] =
      Mana.Explore.run(@domains, Keyword.drop(Explore.options(), [:domains]) ++ [seed: 1]).violations

    violation
  end

  defp check(trace), do: Mana.Explore.check(trace, @domains, setup: &Explore.actors/0)

  test "a saved counterexample fails while the bug is there and passes once it is fixed", %{
    dir: dir
  } do
    path = Mana.Explore.save(found(), dir, "closed-without-reason")
    assert Path.basename(path) == "closed-without-reason.json"

    assert %{
             "property" => "invariant",
             "verb" => "closed_has_reason",
             "resources" => ["ExploreMomentTest.Ticket"],
             "skip_rules" => [],
             "moves" => [_ | _]
           } = Jason.decode!(File.read!(path))

    assert {:failed, %{property: :invariant, resource: Ticket, detail: detail}} = check(path)
    assert detail =~ "closed without a reason"

    Application.put_env(:mana_core, :explore_moment_fixed, true)
    assert check(path) == :passed
    assert check(Jason.decode!(File.read!(path))) == :passed
  end

  test "the check judges the trace on what was explored: other properties and resources do not count",
       %{dir: dir} do
    path = Mana.Explore.save(found(), dir, "closed-without-reason")
    Application.put_env(:mana_core, :explore_moment_fixed, true)
    trace = Jason.decode!(File.read!(path))

    assert check(trace) == :passed

    assert {:failed, %{resource: Elsewhere}} =
             check(
               Map.put(trace, "resources", [
                 "ExploreMomentTest.Ticket",
                 "ExploreMomentTest.Elsewhere"
               ])
             )

    assert check(Map.put(trace, "skip_rules", ["closed_has_reason"])) == :passed
  end

  test "a trace naming what the app no longer has is an error, never a pass", %{dir: dir} do
    trace =
      dir |> then(&Mana.Explore.save(found(), &1, "stale")) |> File.read!() |> Jason.decode!()

    gone = Map.put(trace, "resources", ["ExploreMomentTest.Gone"])

    assert_raise ArgumentError, fn -> check(gone) end
    assert_raise ArgumentError, fn -> check(%{trace | "property" => "whatever_else"}) end
  end

  test "mix mana.explore --save writes the counterexample as a named Moment, and refuses a name in use",
       %{dir: dir} do
    Application.put_env(:mana_core, :explore, Explore)
    Mix.shell(Mix.Shell.Process)

    try do
      assert catch_exit(Mix.Tasks.Mana.Explore.run(["--save", "closed_ticket", "--out", dir])) ==
               {:shutdown, 1}

      assert_raise Mix.Error, ~r/saved already/, fn ->
        Mix.Tasks.Mana.Explore.run(["--save", "closed-ticket", "--out", dir])
      end

      assert_raise Mix.Error, ~r/Moment name/, fn ->
        Mix.Tasks.Mana.Explore.run(["--save", "Closed Ticket", "--out", dir])
      end
    after
      Mix.shell(Mix.Shell.IO)
    end

    assert_received {:mix_shell, :info, ["saved Moment closed-ticket: " <> path]}
    assert File.ls!(dir) == ["closed-ticket.json"]
    assert {:failed, %{property: :invariant}} = check(path)
  end
end
