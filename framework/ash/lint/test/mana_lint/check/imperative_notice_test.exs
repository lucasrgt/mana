defmodule ManaLint.Check.ImperativeNoticeTest do
  use Credo.Test.Case

  alias ManaLint.Check.ImperativeNotice, as: Check

  test "a notice sent from an action's code" do
    """
    defmodule App.Bookings.Accept do
      use Ash.Resource.Change
      alias App.Notifications

      def change(changeset, _, _) do
        Ash.Changeset.after_action(changeset, fn _, booking ->
          Notifications.notify!(booking.traveler_id, "booking.accepted", %{})
          {:ok, booking}
        end)
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Notifications.notify!"
      assert issue.message =~ "Declare it in the resource's `notifications`"
    end)
  end

  test "the sender delivers by hand, and Mana's own notifications are left alone" do
    """
    defmodule App.Notifications.Sender do
      @behaviour Mana.Notifications.Sender

      @impl true
      def deliver(%{to: to, template: template, payload: payload}), do: inbox(to, template, payload)

      defp inbox(to, template, payload),
        do: App.Notifications.notify!(to, template, payload, authorize?: false)
    end

    defmodule Mana.Notifications.Outbox do
      def run(notice), do: Mana.Notifications.notify(notice)
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
