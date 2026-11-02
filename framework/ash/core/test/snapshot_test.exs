defmodule SnapshotTest.Repo do
  use Ecto.Repo, otp_app: :mana_core, adapter: Ecto.Adapters.Postgres
end

defmodule Mana.SnapshotTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias Ash.Domain.Info
  alias Mana.Snapshot.Plug, as: ScopePlug

  @repo SnapshotTest.Repo
  @migrations Path.expand("support/snapshot_migrations", __DIR__)

  setup_all do
    url = System.get_env("MANA_TEST_POSTGRES")
    Application.put_env(:mana_core, SnapshotTest.Repo, url: url, pool_size: 2, log: false)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    :ok
  end

  setup do
    on_exit(fn -> for id <- Mana.Snapshot.scopes(@repo), do: Mana.Snapshot.drop(@repo, id) end)
  end

  defp insert(body),
    do:
      @repo.query!("INSERT INTO notes (id, body) VALUES ($1, $2)", [Ecto.UUID.bingenerate(), body])

  defp bodies, do: @repo.query!("SELECT body FROM notes ORDER BY body").rows |> List.flatten()
  defp open(from \\ :base), do: Mana.Snapshot.open(@repo, from, migrations: @migrations)

  test "two scopes from the same base never see each other's writes" do
    a = open()
    b = open()

    Mana.Snapshot.with_scope(@repo, a, fn -> insert("from a") end)

    assert Mana.Snapshot.with_scope(@repo, a, &bodies/0) == ["from a"]
    assert Mana.Snapshot.with_scope(@repo, b, &bodies/0) == []
  end

  test "a captured scope opens again with the same rows, and forks independently" do
    a = open()
    Mana.Snapshot.with_scope(@repo, a, fn -> insert("kept") end)
    assert Mana.Snapshot.capture(@repo, a, "with-note") == "with-note"
    assert Mana.Snapshot.snapshot?(@repo, "with-note")

    [x, y] = Mana.Snapshot.fork(@repo, "with-note", 2)
    Mana.Snapshot.with_scope(@repo, x, fn -> insert("only x") end)

    assert Mana.Snapshot.with_scope(@repo, x, &bodies/0) == ["kept", "only x"]
    assert Mana.Snapshot.with_scope(@repo, y, &bodies/0) == ["kept"]
    # the captured scope stays usable
    assert Mana.Snapshot.with_scope(@repo, a, &bodies/0) == ["kept"]

    assert %{tables: %{"notes" => {2, 1}}} = Mana.Snapshot.diff(@repo, x, y)
    assert Mana.Snapshot.diff(@repo, y, y).tables == %{}

    Mana.Snapshot.drop_snapshot(@repo, "with-note")
    refute Mana.Snapshot.snapshot?(@repo, "with-note")
  end

  test "an unknown snapshot or a bad name is refused" do
    assert_raise ArgumentError, ~r/no snapshot/, fn -> open("missing") end

    assert_raise ArgumentError, ~r/lowercase/, fn ->
      Mana.Snapshot.capture(@repo, "x", "Bad Name")
    end
  end

  test "the plug routes a request to its scope only when scopes are on" do
    a = open()
    Mana.Snapshot.with_scope(@repo, a, fn -> insert("scoped") end)

    request = fn header ->
      Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("x-mana-data-scope", header)
    end

    Application.put_env(:mana_core, :data_scopes, false)
    conn = ScopePlug.call(request.(a), @repo)
    refute conn.halted
    assert @repo.get_dynamic_repo() == @repo

    Application.put_env(:mana_core, :data_scopes, true)
    conn = ScopePlug.call(request.("nope"), @repo)
    assert conn.status == 409

    ScopePlug.call(request.(a), @repo)
    assert bodies() == ["scoped"]
  after
    @repo.put_dynamic_repo(@repo)
    Application.delete_env(:mana_core, :data_scopes)
  end

  test "snapshot_reset gives each exploration run a scope of its own and drops it after" do
    reset = Mana.Explore.snapshot_reset(@repo, :base, migrations: @migrations)
    test = self()

    combined = fn run ->
      for r <- Info.resources(ExploreTest.Domain), do: Mana.Explore.empty_ets(r)
      reset.(run)
      if run != :done, do: send(test, {:scope, @repo.get_dynamic_repo()})
      :ok
    end

    Mana.Explore.run([ExploreTest.Domain],
      resources: [ExploreTest.Card],
      actors: %{ana: nil},
      runs: 3,
      depth: 2,
      seed: 1,
      reset: combined,
      shrink: false
    )

    scopes = for _ <- 1..3, do: assert_received({:scope, pid}) && pid
    assert Enum.uniq(scopes) |> length() == 3
    assert Mana.Snapshot.scopes(@repo) == []
    assert @repo.get_dynamic_repo() == @repo
  end
end
