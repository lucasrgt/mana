if Code.ensure_loaded?(Postgrex) and Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mana.Snapshot do
    @moduledoc """
    A situation's data as a Postgres database cloned from a template, so it
    opens in milliseconds and forks without the copies seeing each other.

        base = Mana.Snapshot.base!(MyApp.Repo)                 # migrated, empty, built once per migration set
        scope = Mana.Snapshot.open(MyApp.Repo)                 # a database of its own, cloned from base
        Mana.Snapshot.with_scope(MyApp.Repo, scope, fn -> ... end)
        Mana.Snapshot.capture(MyApp.Repo, scope, "booking-paid")
        [a, b] = Mana.Snapshot.fork(MyApp.Repo, "booking-paid", 2)
        Mana.Snapshot.diff(MyApp.Repo, a, b, logs: [MyApp.HistoryEntry])
        Mana.Snapshot.drop(MyApp.Repo, a)

    A **scope** is one cloned database and its own pool, started as a
    dynamic repo (`repo.put_dynamic_repo/1`): code that runs inside
    `with_scope/3`, or a request carrying `x-mana-data-scope` through
    `Mana.Snapshot.Plug`, reads and writes there. A **snapshot** is a scope
    frozen under a name. Cloning uses `CREATE DATABASE … TEMPLATE`, which
    needs no connection to the source: a scope's pool is stopped while it is
    captured and started again after.

    Only for development and tests (`config :mana_core, data_scopes: true`
    for the plug). What runs in other processes does not follow the scope:
    Ash's async loads (set `config :ash, disable_async?: true` where scopes
    are used) and Oban's queues, which poll the main database — move time in
    a scope with `Mana.Explore` or `Mana.Intervene` instead.
    """

    @doc """
    The migrated template, built when the repo's migrations change; answers
    its database name. `migrations:` overrides the repo's migrations folder.
    """
    def base!(repo, opts \\ []) do
      dir = opts[:migrations] || Ecto.Migrator.migrations_path(repo)
      name = database_name(repo, "base_" <> migrations_hash(dir))

      unless exists?(repo, name) do
        tmp = name <> "_building"
        drop_database(repo, tmp)
        admin(repo, ~s(CREATE DATABASE "#{tmp}" TEMPLATE template0))
        {:ok, pid} = start_repo(repo, tmp)

        try do
          Ecto.Migrator.run(repo, dir, :up, all: true, dynamic_repo: pid, log: false)
        after
          stop_repo(pid)
        end

        admin(repo, ~s(ALTER DATABASE "#{tmp}" RENAME TO "#{name}"))
      end

      name
    end

    @doc "A new scope cloned from the base (or from snapshot `from`); answers its id. Takes `base!/2`'s options."
    def open(repo, from \\ :base, opts \\ []) do
      source = if from == :base, do: base!(repo, opts), else: snapshot_database(repo, from)
      unless exists?(repo, source), do: raise(ArgumentError, "no snapshot #{inspect(from)}")
      id = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
      clone(repo, source, scope_database(repo, id))
      {:ok, _pid} = Mana.Snapshot.Scopes.start_scope(repo, id, scope_database(repo, id))
      id
    end

    @doc "`n` scopes cloned from snapshot `name`."
    def fork(repo, name, n) when n > 0, do: for(_ <- 1..n, do: open(repo, name))

    @doc "Freezes scope `id` as snapshot `name` (replacing one of that name); the scope stays open."
    def capture(repo, id, name) do
      valid_name!(name)
      target = snapshot_database(repo, name)

      Mana.Snapshot.Scopes.paused(repo, id, fn database ->
        drop_database(repo, target)
        clone(repo, database, target)
      end)

      name
    end

    @doc "Whether snapshot `name` exists."
    def snapshot?(repo, name), do: exists?(repo, snapshot_database(repo, name))

    @doc "Drops scope `id`: its pool and its database."
    def drop(repo, id) do
      Mana.Snapshot.Scopes.stop_scope(repo, id)
      drop_database(repo, scope_database(repo, id))
      :ok
    end

    @doc "Drops snapshot `name`."
    def drop_snapshot(repo, name), do: drop_database(repo, snapshot_database(repo, name))

    @doc "The ids of the scopes open now."
    def scopes(repo), do: Mana.Snapshot.Scopes.ids(repo)

    @doc "Runs `fun` with `repo` pointed at scope `id`."
    def with_scope(repo, id, fun) do
      pid = Mana.Snapshot.Scopes.pid!(repo, id)
      previous = repo.put_dynamic_repo(pid)

      try do
        fun.()
      after
        repo.put_dynamic_repo(previous)
      end
    end

    @doc "Points `repo` at scope `id` for the rest of this process (what the plug does)."
    def use_scope(repo, id), do: repo.put_dynamic_repo(Mana.Snapshot.Scopes.pid!(repo, id))

    @doc """
    How scopes `a` and `b` differ: row counts per table that differ, and,
    for each `Mana.History.Log` resource in `logs`, the history entries one
    has and the other does not (by subject, action, verb and outcome) —
    what each did since they were cloned from the same snapshot.
    """
    def diff(repo, a, b, opts \\ []) do
      counts_a = with_scope(repo, a, fn -> counts(repo) end)
      counts_b = with_scope(repo, b, fn -> counts(repo) end)

      tables =
        for table <- Enum.uniq(Map.keys(counts_a) ++ Map.keys(counts_b)),
            Map.get(counts_a, table) != Map.get(counts_b, table),
            into: %{},
            do: {table, {Map.get(counts_a, table, 0), Map.get(counts_b, table, 0)}}

      history =
        for log <- Keyword.get(opts, :logs, []), into: %{} do
          entries_a = with_scope(repo, a, fn -> entries(log) end)
          entries_b = with_scope(repo, b, fn -> entries(log) end)
          {log, %{only_a: entries_a -- entries_b, only_b: entries_b -- entries_a}}
        end

      %{tables: tables, history: history}
    end

    defp counts(repo) do
      %{rows: tables} =
        repo.query!(
          "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename",
          [],
          log: false
        )

      for [table] <- tables, table != "schema_migrations", into: %{} do
        %{rows: [[count]]} = repo.query!("SELECT count(*) FROM \"#{table}\"", [], log: false)
        {table, count}
      end
    end

    defp entries(log) do
      log
      |> Ash.read!(authorize?: false)
      |> Enum.map(
        &%{
          subject: "#{&1.subject_type}:#{&1.subject_id}",
          action: &1.action,
          verb: &1.verb,
          outcome: to_string(&1.outcome)
        }
      )
      |> Enum.sort_by(&{&1.subject, &1.action})
    end

    # -------------------------------------------------------------------------

    @doc false
    def start_repo(repo, database) do
      # A scope is a database of its own: it never shares a test's sandbox pool.
      config =
        Keyword.merge(config(repo),
          database: database,
          pool_size: 2,
          name: nil,
          url: nil,
          pool: DBConnection.ConnectionPool
        )

      repo.start_link(config)
    end

    # A url in the config wins over :database when the pool starts, so it is
    # expanded into its parts first.
    defp config(repo) do
      config = repo.config()

      case Keyword.pop(config, :url) do
        {nil, config} -> config
        {url, config} -> Keyword.merge(config, Ecto.Repo.Supervisor.parse_url(url))
      end
    end

    @doc false
    def stop_repo(pid) do
      ref = Process.monitor(pid)
      Supervisor.stop(pid, :normal)

      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      after
        5_000 -> :ok
      end
    catch
      :exit, _ -> :ok
    end

    defp clone(repo, source, target) do
      strategy = if server_version(repo) >= 150_000, do: " STRATEGY FILE_COPY", else: ""
      admin(repo, ~s(CREATE DATABASE "#{target}" TEMPLATE "#{source}"#{strategy}))
    end

    defp drop_database(repo, name) do
      force = if server_version(repo) >= 130_000, do: " WITH (FORCE)", else: ""
      admin(repo, ~s(DROP DATABASE IF EXISTS "#{name}"#{force}))
    end

    defp exists?(repo, name) do
      %{rows: rows} = admin(repo, "SELECT 1 FROM pg_database WHERE datname = $1", [name])
      rows != []
    end

    defp server_version(repo) do
      %{rows: [[version]]} = admin(repo, "SHOW server_version_num")
      String.to_integer(version)
    end

    # Database statements run on the maintenance database, never inside the
    # app's pool (CREATE DATABASE cannot run in a transaction, and the source
    # must have no connections).
    defp admin(repo, sql, params \\ []) do
      config =
        repo
        |> config()
        |> Keyword.take([:hostname, :port, :username, :password, :socket_dir, :ssl, :socket])
        |> Keyword.put(:database, "postgres")

      {:ok, conn} = Postgrex.start_link(config)

      try do
        Postgrex.query!(conn, sql, params)
      after
        GenServer.stop(conn)
      end
    end

    defp migrations_hash(dir) do
      files = dir |> Path.join("**/*.exs") |> Path.wildcard() |> Enum.sort()

      :crypto.hash(:sha256, Enum.map(files, &[Path.relative_to(&1, dir), File.read!(&1)]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 12)
    end

    defp database_name(repo, suffix), do: "#{config(repo)[:database]}_mana_#{suffix}"
    defp scope_database(repo, id), do: database_name(repo, "s_" <> id)

    defp snapshot_database(repo, name),
      do: valid_name!(name) && database_name(repo, "m_" <> String.replace(name, "-", "_"))

    defp valid_name!(name) do
      if is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_-]{0,30}$/, name),
        do: true,
        else:
          raise(
            ArgumentError,
            "snapshot names are lowercase letters, digits, - and _ (#{inspect(name)})"
          )
    end
  end

  defmodule Mana.Snapshot.Scopes do
    @moduledoc false
    # Owns the scopes' pools, so a scope outlives the request or test process
    # that opened it.
    use GenServer

    def start_scope(repo, id, database), do: call({:start, repo, id, database})
    def stop_scope(repo, id), do: call({:stop, repo, id})

    def pid!(repo, id),
      do: call({:pid, repo, id}) || raise(ArgumentError, "no data scope #{inspect(id)}")

    def pid(repo, id), do: call({:pid, repo, id})
    def ids(repo), do: call({:ids, repo})
    def paused(repo, id, fun), do: call({:paused, repo, id, fun}, 60_000)

    defp call(message, timeout \\ 15_000) do
      server = GenServer.whereis(__MODULE__) || start()
      GenServer.call(server, message, timeout)
    end

    defp start do
      case GenServer.start(__MODULE__, %{}, name: __MODULE__) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end
    end

    @impl true
    def init(state) do
      Process.flag(:trap_exit, true)
      {:ok, state}
    end

    @impl true
    def handle_call({:start, repo, id, database}, _from, state) do
      case Mana.Snapshot.start_repo(repo, database) do
        {:ok, pid} ->
          {:reply, {:ok, pid}, Map.put(state, {repo, id}, %{pid: pid, database: database})}

        error ->
          {:reply, error, state}
      end
    end

    def handle_call({:stop, repo, id}, _from, state) do
      case Map.pop(state, {repo, id}) do
        {nil, state} ->
          {:reply, :ok, state}

        {%{pid: pid}, state} ->
          Mana.Snapshot.stop_repo(pid)
          {:reply, :ok, state}
      end
    end

    def handle_call({:pid, repo, id}, _from, state),
      do: {:reply, get_in(state, [{repo, id}, :pid]), state}

    def handle_call({:ids, repo}, _from, state),
      do: {:reply, for({{^repo, id}, _} <- state, do: id), state}

    def handle_call({:paused, repo, id, fun}, _from, state) do
      case Map.get(state, {repo, id}) do
        nil ->
          {:reply, {:error, :no_scope}, state}

        %{pid: pid, database: database} = scope ->
          Mana.Snapshot.stop_repo(pid)
          result = fun.(database)
          {:ok, pid} = Mana.Snapshot.start_repo(repo, database)
          {:reply, result, Map.put(state, {repo, id}, %{scope | pid: pid})}
      end
    end

    @impl true
    def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  end

  if Code.ensure_loaded?(Plug) do
    defmodule Mana.Snapshot.Plug do
      @moduledoc """
      Runs each request that carries `x-mana-data-scope: <id>` on that
      scope (`Mana.Snapshot`): `plug Mana.Snapshot.Plug, repo: MyApp.Repo`.
      Honoured only with `config :mana_core, data_scopes: true`; an unknown
      scope is refused with 409 instead of falling back to the shared
      database, so a suite worker never writes where another reads.
      """
      @behaviour Plug
      import Plug.Conn

      @impl true
      def init(opts), do: Keyword.fetch!(opts, :repo)

      @impl true
      def call(conn, repo) do
        with true <- Application.get_env(:mana_core, :data_scopes, false) == true,
             [id] <- get_req_header(conn, "x-mana-data-scope") do
          case Mana.Snapshot.Scopes.pid(repo, id) do
            nil ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(409, ~s({"errors":[{"code":"data_scope.unknown"}]}))
              |> halt()

            pid ->
              repo.put_dynamic_repo(pid)
              conn
          end
        else
          _ -> conn
        end
      end
    end
  end
end
