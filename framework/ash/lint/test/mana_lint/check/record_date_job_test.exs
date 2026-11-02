defmodule ManaLint.Check.RecordDateJobTest do
  use Credo.Test.Case

  alias ManaLint.Check.RecordDateJob, as: Check

  test "a job scheduled at a record's date, read in place or bound before" do
    """
    defmodule App.Legal.Publish do
      use Ash.Resource.Change

      def change(changeset, _, _), do: Ash.Changeset.after_action(changeset, &announce/2)

      defp announce(_changeset, doc) do
        {:ok, _} = Oban.insert(App.Legal.Announce.new(%{id: doc.id}, scheduled_at: doc.effective_at))
        {:ok, doc}
      end
    end

    defmodule App.Bookings do
      alias App.Bookings.Expire

      def schedule(booking) do
        at = DateTime.add(booking.expires_at, -600, :second)
        %{id: booking.id} |> Expire.new(queue: :bookings, scheduled_at: at) |> Oban.insert!()
      end

      def remind(changeset) do
        due = Ash.Changeset.get_attribute(changeset, :check_in)
        Oban.Job.new(%{}, worker: App.Remind, schedule_in: DateTime.diff(due, DateTime.utc_now()))
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() ==
               ["App.Legal.Announce.new", "Expire.new", "Oban.Job.new"]

      assert Enum.all?(issues, &(&1.message =~ "deadline"))
    end)
  end

  test "a delay, a time from now, an unscheduled job and Mana's own workers are left alone" do
    """
    defmodule App.Search do
      def reindex(place), do: Oban.insert(App.Reindex.new(%{id: place.id}, schedule_in: 30))

      def retry(job, config),
        do: App.Sync.new(job.args, scheduled_at: DateTime.add(DateTime.utc_now(), config.delay))

      def now(place), do: App.Reindex.new(%{id: place.id, at: place.updated_at})
    end

    defmodule Mana.Entity do
      alias Mana.Entity.Worker

      defp insert(%{args: args, deadline: deadline}),
        do: args |> Worker.new(scheduled_at: deadline.due_at) |> Oban.insert!()
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
