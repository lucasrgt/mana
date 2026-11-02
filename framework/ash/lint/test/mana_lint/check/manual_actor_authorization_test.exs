defmodule ManaLint.Check.ManualActorAuthorizationTest do
  use Credo.Test.Case

  alias ManaLint.Check.ManualActorAuthorization, as: Check

  test "an action implementation that reads unauthorized and compares to actor.id" do
    """
    defmodule App.CheckInCodeFor do
      use Ash.Resource.Actions.Implementation

      def run(input, _, %{actor: actor}) do
        case Ash.get(App.Booking, input.arguments.id, authorize?: false) do
          {:ok, %{traveler_id: id} = booking} when id == actor.id -> {:ok, booking.code}
          _ -> {:error, :not_found}
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Ash.get"))
  end

  test "in a helper a change calls, with context.actor" do
    """
    defmodule App.Submit do
      use Ash.Resource.Change

      def change(changeset, _, context), do: check(changeset, context)

      defp check(changeset, context) do
        booking = Ash.get!(App.Booking, changeset.arguments.booking_id, authorize?: false)
        if context.actor.id in [booking.host_id, booking.traveler_id], do: changeset, else: changeset
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Ash.get!"))
  end

  test "a read as the actor, or an actor comparison that is not about the read, is fine" do
    """
    defmodule App.Confirm do
      use Ash.Resource.Actions.Implementation

      def run(input, _, %{actor: actor}) do
        with {:ok, upload} <- Ash.get(App.Upload, input.arguments.id, actor: actor) do
          {:ok, upload.owner_id == actor.id}
        end
      end
    end

    defmodule App.Totals do
      use Ash.Resource.Change

      def change(changeset, _, %{actor: actor}) do
        plan = Ash.read_one!(App.Plan, authorize?: false)
        Ash.Changeset.force_change_attribute(changeset, :plan_id, plan.id)
      end
    end

    defmodule App.Open do
      use Ash.Resource.Actions.Implementation

      def run(input, _, %{actor: actor}) do
        if input.arguments.other_id == actor.id, do: {:error, :self}, else: :ok
        chat = Ash.read_one!(App.Chat, authorize?: false)
        {:ok, chat}
      end
    end

    defmodule App.Plain do
      def lookup(id, actor) do
        {:ok, b} = Ash.get(App.Booking, id, authorize?: false)
        b.owner_id == actor.id
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
