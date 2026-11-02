postgres = System.get_env("MANA_TEST_POSTGRES")

if postgres do
  # A database of this package's own, rebuilt each run, next to the one named.
  url = Ecto.Repo.Supervisor.parse_url(postgres)

  config =
    Keyword.merge(url,
      database: url[:database] <> "_session",
      pool_size: 10,
      force_drop: true,
      log: false
    )

  Application.put_env(:mana_session, SessionTest.Repo, config)
  {:ok, _} = Application.ensure_all_started(:ecto_sql)
  _ = Ecto.Adapters.Postgres.storage_down(config)
  :ok = Ecto.Adapters.Postgres.storage_up(config)
  {:ok, _} = SessionTest.Repo.start_link()
  migrations = Path.expand("support/migrations", __DIR__)
  Ecto.Migrator.run(SessionTest.Repo, migrations, :up, all: true, log: false)
end

ExUnit.start(exclude: if(postgres, do: [], else: [:postgres]))
