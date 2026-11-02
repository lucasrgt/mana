defmodule PostgresTest.Harness do
  @moduledoc false
  # mana_core on a real Postgres (`MANA_TEST_POSTGRES`, a URL): each test
  # module gets the database fresh, cloned from the `Mana.Snapshot` base of
  # migrations/ (so the migration file is compiled once, when the base is
  # built), each test starts from empty tables, and nothing runs in a
  # sandbox, so concurrent tasks hold real transactions and locks. Oban runs
  # in `:manual` testing mode: jobs are rows, run by `Oban.drain_queue/1`
  # when a test asks.
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @repo PostgresTest.Repo
  @migrations Path.expand("migrations", __DIR__)
  @tables ~w(orders history_entries travelers bookings reviews cards ledgers notes ratings threads stays people offerings venues oban_jobs)

  def migrations, do: @migrations

  @doc "For `setup_all`: the repo and Oban running on a migrated database."
  def start! do
    Application.put_env(:mana_core, @repo,
      url: System.fetch_env!("MANA_TEST_POSTGRES"),
      pool_size: 20,
      log: false
    )

    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)
    base = Mana.Snapshot.base!(@repo, migrations: @migrations)
    config = @repo.config()

    {:ok, admin} =
      config
      |> Keyword.take([:hostname, :port, :username, :password])
      |> Keyword.put(:database, "postgres")
      |> Postgrex.start_link()

    try do
      Postgrex.query!(
        admin,
        ~s|DROP DATABASE IF EXISTS "#{config[:database]}" WITH (FORCE)|,
        []
      )

      Postgrex.query!(admin, ~s|CREATE DATABASE "#{config[:database]}" TEMPLATE "#{base}"|, [])
    after
      GenServer.stop(admin)
    end

    start_supervised!(@repo)
    start_supervised!({Oban, repo: @repo, testing: :manual})
    :ok
  end

  @doc "For `setup`: empty tables, and messages from the probe to this test."
  def reset! do
    @repo.query!("TRUNCATE #{Enum.join(@tables, ", ")}")
    Application.put_env(:mana_core, :postgres_test_pid, self())
    :ok
  end

  @doc "How many deadline jobs there are, of any record or of record `id`."
  def deadline_jobs(id \\ nil) do
    %{rows: [[count]]} =
      @repo.query!(
        "SELECT count(*) FROM oban_jobs WHERE worker = 'Mana.Entity.Worker' AND ($1::text IS NULL OR args->>'id' = $1)",
        [id]
      )

    count
  end

  @doc "Starts `funs` at once, each in its own process, and answers their results in order."
  def race(funs) do
    gate = make_ref()
    parent = self()

    tasks =
      for fun <- funs do
        Task.async(fn ->
          send(parent, {:ready, gate})

          receive do
            {:go, ^gate} -> fun.()
          end
        end)
      end

    for _ <- tasks, do: assert_ready(gate)
    for task <- tasks, do: send(task.pid, {:go, gate})
    Task.await_many(tasks, 30_000)
  end

  defp assert_ready(gate) do
    receive do
      {:ready, ^gate} -> :ok
    after
      5_000 -> raise "a racer did not start"
    end
  end
end
