defmodule ManaLint.Check.ValidationAsChangeTest do
  use Credo.Test.Case

  alias ManaLint.Check.ValidationAsChange, as: Check

  test "add_error on the changeset's data and arguments" do
    """
    defmodule App.Cancel do
      use Ash.Resource.Change

      def change(changeset, _, %{actor: actor}) do
        booking = changeset.data

        cond do
          booking.status in [:completed, :cancelled] ->
            Ash.Changeset.add_error(changeset, :invalid_transition)

          not App.Legal.cleared?(actor) ->
            Ash.Changeset.add_error(changeset, :legal_pending)

          true ->
            changeset
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(fn issue ->
      assert issue.trigger == "Ash.Changeset.add_error"
      assert issue.line_no == 9
    end)
  end

  test "a condition through the module's own pure helpers and a getter function" do
    """
    defmodule App.Shape do
      use Ash.Resource.Change
      alias Ash.Changeset

      @checks [weekdays: :weekdays_invalid, schedule: :schedule_invalid]

      def change(changeset, _, _) do
        get = &Changeset.get_attribute(changeset, &1)

        case Enum.find(@checks, fn {check, _} -> fails?(check, get) end) do
          {_, problem} -> Changeset.add_error(changeset, problem)
          nil -> changeset
        end
      end

      defp fails?(:weekdays, get), do: (get.(:weekdays) || []) == []
      defp fails?(:schedule, get), do: Date.compare(get.(:end_date), get.(:start_date)) == :lt
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issue(&assert(&1.trigger == "Changeset.add_error"))
  end

  test "an error that follows a query or an external call is left alone" do
    """
    defmodule App.Capture do
      use Ash.Resource.Change

      def change(changeset, _, _) do
        result = App.Billing.capture(changeset.data)

        if result == :declined do
          Ash.Changeset.add_error(changeset, :declined)
        else
          case Ash.read_one(App.Hold) do
            {:ok, nil} -> Ash.Changeset.add_error(changeset, :no_hold)
            {:ok, hold} -> if hold.amount > 0, do: changeset, else: Ash.Changeset.add_error(changeset, :empty)
          end
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end

  test "errors inside hooks, and outside changes, are not flagged" do
    """
    defmodule App.Late do
      use Ash.Resource.Change

      def change(changeset, _, _) do
        Ash.Changeset.before_action(changeset, fn changeset ->
          if changeset.data.locked, do: Ash.Changeset.add_error(changeset, :locked), else: changeset
        end)
      end
    end

    defmodule App.Helper do
      def check(changeset), do: if(changeset.data.locked, do: Ash.Changeset.add_error(changeset, :x))
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
