defmodule NoticeOutboxTest.Repo do
  use AshPostgres.Repo, otp_app: :mana_core, warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule NoticeOutboxTest.ObanJobs do
  use Ecto.Migration

  def up, do: Oban.Migration.up()
  def down, do: Oban.Migration.down()
end

defmodule NoticeOutboxTest.Sender do
  @behaviour Mana.Notifications.Sender

  # Fails the email channel as many times as `:outbox_email_failures` says.
  def deliver(notice) do
    send(Application.get_env(:mana_core, :outbox_test_pid), {:notice, notice.channels})
    failures = Application.get_env(:mana_core, :outbox_email_failures)

    if :email in notice.channels and :counters.get(failures, 1) > 0 do
      :counters.sub(failures, 1, 1)
      {:failed, [email: :unreachable]}
    else
      :ok
    end
  end
end

defmodule NoticeOutboxTest.Alert do
  use Ash.Resource,
    domain: NoticeOutboxTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Notifications]

  postgres do
    table("outbox_alerts")
    repo(NoticeOutboxTest.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, create: [:user_id]])
  end

  notifications do
    sender(NoticeOutboxTest.Sender)
    notify(:create, to: :user_id, template: "alert.raised", channels: [:inbox, :email])
  end
end

defmodule NoticeOutboxTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(NoticeOutboxTest.Alert)
  end
end

defmodule Mana.NoticeOutboxTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias NoticeOutboxTest.Alert
  alias NoticeOutboxTest.Repo

  setup_all do
    # A database of its own, next to the one MANA_TEST_POSTGRES names.
    url = System.fetch_env!("MANA_TEST_POSTGRES") <> "_outbox"
    Application.put_env(:mana_core, Repo, url: url, pool_size: 4, log: false)
    {:ok, _} = Application.ensure_all_started(:ash_postgres)
    _ = Repo.__adapter__().storage_up(Repo.config())

    start_supervised!(Repo)

    Repo.query!(
      "CREATE TABLE IF NOT EXISTS outbox_alerts (id uuid PRIMARY KEY, user_id uuid)",
      []
    )

    Ecto.Migrator.up(Repo, 1, NoticeOutboxTest.ObanJobs, log: false)
    start_supervised!({Oban, repo: Repo, testing: :manual})
    :ok
  end

  setup do
    Repo.query!("TRUNCATE outbox_alerts, oban_jobs", [])
    failures = :counters.new(1, [])
    Application.put_env(:mana_core, :outbox_test_pid, self())
    Application.put_env(:mana_core, :outbox_email_failures, failures)

    on_exit(fn ->
      Application.delete_env(:mana_core, :outbox_test_pid)
      Application.delete_env(:mana_core, :outbox_email_failures)
    end)

    %{failures: failures}
  end

  defp jobs,
    do:
      Repo.query!("SELECT args->>'stage', state FROM oban_jobs ORDER BY id", []).rows
      |> Enum.map(&List.to_tuple/1)

  defp drain, do: Oban.drain_queue(queue: :default, with_scheduled: true)

  test "the notice commits with the change as a job, and is delivered by it once" do
    assert Mana.Notifications.outbox?(Alert)
    Ash.create!(Alert, %{user_id: Ash.UUID.generate()})

    assert jobs() == [{"deliver", "available"}]
    refute_received {:notice, _}

    assert %{success: 1} = drain()
    assert_received {:notice, [:inbox, :email]}
    refute_received {:notice, _}
  end

  test "a change that rolls back leaves no notice behind" do
    assert {:error, :undone} =
             Repo.transaction(fn ->
               Ash.create!(Alert, %{user_id: Ash.UUID.generate()}, return_notifications?: true)
               assert [{"deliver", "available"}] = jobs()
               Repo.rollback(:undone)
             end)

    assert jobs() == []
    assert drain() == %{cancelled: 0, discard: 0, failure: 0, snoozed: 0, success: 0}
    refute_received {:notice, _}
  end

  test "a channel the sender failed is tried again on its own; those that went out are not resent",
       %{failures: failures} do
    :counters.put(failures, 1, 2)
    Ash.create!(Alert, %{user_id: Ash.UUID.generate()})

    assert %{success: 1} = Oban.drain_queue(queue: :default)
    assert_received {:notice, [:inbox, :email]}
    assert [{"deliver", "completed"}, {"send", "available"}] = jobs()

    assert %{failure: 1} = Oban.drain_queue(queue: :default)
    assert_received {:notice, [:email]}
    assert [_, {"send", "retryable"}] = jobs()

    assert %{success: 1} = drain()
    assert_received {:notice, [:email]}
    refute_received {:notice, _}
    assert [_, {"send", "completed"}] = jobs()
  end
end
