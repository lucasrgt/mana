if Code.ensure_loaded?(Oban.Job) do
  defmodule Mana.Intervene do
    @moduledoc """
    `clock` interventions: see what time does to the app without waiting for
    it. `advance/2` performs now the durable jobs Mana schedules for later —
    `Mana.Entity` deadlines and `Mana.Flow` stuck checks — that would come due
    within `by` (`{3, :day}`), as if that much time had passed, each still
    checking its own condition first. `mix mana.advance 3d` does it on a
    development database. Network interventions are the client's
    (`MomentIntervention` in live_ui: `net:<path>=offline|api-error|slow|empty`);
    counterfactuals over a recorded run are `Mana.History.replay/3` with
    rewritten `params`.
    """
    require Ecto.Query

    @workers ["Mana.Entity.Worker", "Mana.Flow.Worker"]

    @doc "Performs the deadline and stuck-flow jobs due within `by`; answers what ran."
    def advance(repo, {amount, unit}) do
      horizon = DateTime.add(DateTime.utc_now(), amount, unit)

      jobs =
        Oban.Job
        |> Ecto.Query.where([j], j.worker in @workers and j.state in ["scheduled", "available", "retryable"] and j.scheduled_at <= ^horizon)
        |> Ecto.Query.order_by([j], asc: j.scheduled_at)
        |> repo.all()

      for job <- jobs do
        worker = job.worker |> String.split(".") |> Module.safe_concat()
        result = worker.perform(job)
        repo.delete!(job)
        %{worker: job.worker, args: job.args, due: job.scheduled_at, result: inspect(result)}
      end
    end

    @doc "`\"3d\"`, `\"12h\"`, `\"30m\"` → `{3, :day}`…"
    def parse(text) do
      case Regex.run(~r/^(\d+)([dhm])$/, text) do
        [_, n, "d"] -> {String.to_integer(n), :day}
        [_, n, "h"] -> {String.to_integer(n), :hour}
        [_, n, "m"] -> {String.to_integer(n), :minute}
        _ -> raise ArgumentError, "use a duration like 3d, 12h or 30m"
      end
    end
  end
end
