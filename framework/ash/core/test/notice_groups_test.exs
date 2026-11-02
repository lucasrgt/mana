defmodule NoticeGroupsTest.Sender do
  @behaviour Mana.Notifications.Sender
  def deliver(notice) do
    send(
      Application.get_env(:mana_core, :groups_test_pid),
      {:notice, Map.delete(notice, :record)}
    )

    :ok
  end
end

defmodule NoticeGroupsTest.Alert do
  use Ash.Resource,
    domain: NoticeGroupsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Notifications]

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, create: [:user_id]])
  end

  notifications do
    sender(NoticeGroupsTest.Sender)
    group_within({1, :minute})
    notify(:create, to: :user_id, template: "alert.raised", channels: [:inbox, :email])
  end
end

defmodule NoticeGroupsTest.Note do
  use Ash.Resource,
    domain: NoticeGroupsTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Notifications]

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, create: [:user_id]])
  end

  notifications do
    sender(NoticeGroupsTest.Sender)
    notify(:create, to: :user_id, template: "note.added", channels: [:inbox, :email])
  end
end

defmodule NoticeGroupsTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(NoticeGroupsTest.Alert)
    resource(NoticeGroupsTest.Note)
  end
end

defmodule Mana.NoticeGroupsTest do
  use ExUnit.Case, async: false

  alias Mana.Notifications.Groups
  alias NoticeGroupsTest.Alert

  setup do
    Application.put_env(:mana_core, :groups_test_pid, self())
    on_exit(fn -> Application.delete_env(:mana_core, :groups_test_pid) end)
  end

  defp notice(user),
    do: %{
      to: user,
      template: "alert.raised",
      category: :general,
      channels: [:inbox, :email],
      opens: nil,
      payload: %{"alert_id" => "same"},
      record: nil
    }

  describe "without Mana.Notifications.Groups running" do
    test "an action that would group is refused before it writes, naming the missing child" do
      refute Groups.started?()

      assert {:error, error} = Ash.create(Alert, %{user_id: Ash.UUID.generate()})
      assert Exception.message(error) =~ "Mana.Notifications.Groups is not running"
      assert Ash.read!(Alert) == []
      refute_received {:notice, _}

      assert_raise RuntimeError, ~r/supervision tree/, fn -> Groups.count(:key, 1_000) end
    end

    test "a resource that does not group needs no child" do
      user = Ash.UUID.generate()
      Ash.create!(NoticeGroupsTest.Note, %{user_id: user})
      assert_received {:notice, %{to: ^user, channels: [:inbox, :email]}}
    end
  end

  describe "with Mana.Notifications.Groups running" do
    setup do
      start_supervised!({Groups, sweep_every: 60_000})
      :ok
    end

    test "identical notices at once: one goes out in full, the others reach the inbox, each counted once" do
      user = Ash.UUID.generate()

      tasks =
        for _ <- 1..50 do
          Task.async(fn ->
            receive do
              :go -> Mana.Notifications.deliver(Alert, notice(user))
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :go))
      results = Task.await_many(tasks)

      assert Enum.count(results, &(&1 == [:inbox, :email])) == 1
      assert Enum.count(results, &(&1 == [:inbox])) == 49

      counts =
        for _ <- 1..50 do
          receive do
            {:notice, notice} -> notice[:group][:count]
          after
            1_000 -> flunk("a notice did not reach the sender")
          end
        end

      assert Enum.sort(Enum.reject(counts, &is_nil/1)) == Enum.to_list(2..50)
    end

    test "a window that closed opens again; the sweep drops closed windows and keeps open ones" do
      at = System.system_time(:millisecond) - 10_000

      assert Groups.count(:closing, 100, at) == 1
      assert Groups.count(:closing, 100, at + 50) == 2
      assert Groups.count(:closing, 100, at + 150) == 1
      assert Groups.count(:open, 60_000) == 1

      send(Groups, :sweep)
      :sys.get_state(Groups)

      assert :ets.info(Groups, :size) == 1
      assert Groups.count(:open, 60_000) == 2
      assert Groups.count(:closing, 100, at + 200) == 1
    end

    test "the table belongs to the supervised process and is empty again when it starts over" do
      owner = Process.whereis(Groups)
      assert :ets.info(Groups, :owner) == owner
      assert Groups.count(:kept, 60_000) == 1

      stop_supervised!(Groups)
      restarted = start_supervised!(Groups)
      assert :ets.info(Groups, :owner) == restarted
      assert Groups.count(:kept, 60_000) == 1
    end
  end
end
