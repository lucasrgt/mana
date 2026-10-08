defmodule Mix.Tasks.Mana.Checkpoint do
  @shortdoc "Dry-runs (or keeps) an agent's plan of verb steps"
  @moduledoc """
      mix mana.checkpoint --plan plan.json --actor <user id> --actor-resource MyApp.Accounts.User
      mix mana.checkpoint --plan plan.json --actor <id> --actor-resource ... --keep --verdict verdict.json

  The plan is a JSON list of `{"resource", "id", "verb", "params"}`. Without
  `--keep` it runs inside a transaction that is rolled back and prints what
  would change; with `--keep` it runs for real only if the verdict file (from
  `mana sense`) passed. Prints one JSON report.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [plan: :string, actor: :string, actor_resource: :string, keep: :boolean, verdict: :string])
    Mix.Task.run("app.start")

    plan = opts |> Keyword.fetch!(:plan) |> File.read!() |> Jason.decode!()
    actor_resource = opts |> Keyword.fetch!(:actor_resource) |> String.split(".") |> Module.safe_concat()
    actor = Ash.get!(actor_resource, Keyword.fetch!(opts, :actor), authorize?: false)

    result =
      if opts[:keep],
        do: Mana.Checkpoint.keep(plan, actor, opts |> Keyword.fetch!(:verdict) |> File.read!() |> Jason.decode!()),
        else: Mana.Checkpoint.dry_run(plan, actor)

    case result do
      {:ok, report} -> Mix.shell().info(Jason.encode!(report, pretty: true))
      {:error, error} -> Mix.raise("checkpoint refused: #{inspect(error)}")
    end
  end
end
