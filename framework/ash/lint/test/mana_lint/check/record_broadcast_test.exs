defmodule ManaLint.Check.RecordBroadcastTest do
  use Credo.Test.Case

  alias ManaLint.Check.RecordBroadcast, as: Check

  test "a broadcast in a change, a notifier, or next to an Ash write" do
    """
    defmodule App.Bookings.Announce do
      use Ash.Resource.Change

      def change(changeset, _, _) do
        Ash.Changeset.after_transaction(changeset, fn _, {:ok, booking} = result ->
          MyAppWeb.Endpoint.broadcast("booking:" <> booking.id, "changed", %{})
          result
        end)
      end
    end

    defmodule App.Bookings.Notifier do
      use Ash.Notifier
      alias Phoenix.PubSub

      def notify(%{data: booking}), do: PubSub.broadcast(App.PubSub, "bookings", booking)
    end

    defmodule App.Bookings do
      def accept(booking, actor) do
        accepted = Ash.update!(booking, %{}, action: :accept, actor: actor)
        Phoenix.PubSub.broadcast!(App.PubSub, "booking:" <> accepted.id, {:accepted, accepted})
        accepted
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() ==
               ["MyAppWeb.Endpoint.broadcast", "Phoenix.PubSub.broadcast!", "PubSub.broadcast"]

      assert Enum.all?(issues, &(&1.message =~ "Mana.Entity"))
    end)
  end

  test "presence, a channel's messages and the entity's broadcaster are left alone" do
    """
    defmodule AppWeb.ChatChannel do
      use Phoenix.Channel

      def handle_in("typing", _, socket) do
        AppWeb.Endpoint.broadcast_from(self(), socket.topic, "typing", %{})
        {:noreply, socket}
      end
    end

    defmodule App.Broadcast do
      def broadcast(topic, event, payload),
        do: Phoenix.PubSub.broadcast(App.PubSub, topic, {event, payload})
    end

    defmodule App.Presence do
      def joined(user), do: Phoenix.PubSub.broadcast(App.PubSub, "presence", {:joined, user.id})
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
