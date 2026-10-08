defmodule Mana.Retention do
  @moduledoc """
  Deletes rows past their declared retention (`retention do delete_after ... end`).
  Run `purge/1` on a schedule; `Mana.Retention.Worker` does that under Oban.
  """
  require Ash.Query

  @doc "Purges every resource of `domains`; returns the number of rules applied."
  def purge(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        rule <- Mana.Resource.Info.retention(resource) do
      cutoff = DateTime.add(DateTime.utc_now(), -rule.days, :day)

      resource
      |> Ash.Query.filter(^Ash.Expr.ref(rule.field) <= ^cutoff)
      |> Ash.bulk_destroy!(rule.action, %{}, authorize?: false, strategy: [:atomic, :stream])
    end
    |> length()
  end
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Retention.Worker do
    @moduledoc """
    Schedule with Oban's cron plugin, passing the app whose `ash_domains` to purge:

        {"*/15 * * * *", Mana.Retention.Worker, args: %{otp_app: "my_app"}}
    """
    use Oban.Worker, queue: :maintenance, max_attempts: 3

    @impl true
    def perform(%Oban.Job{args: %{"otp_app" => otp_app}}) do
      otp_app |> String.to_existing_atom() |> Application.fetch_env!(:ash_domains) |> Mana.Retention.purge()
      :ok
    end
  end
end
