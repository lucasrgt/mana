defmodule Mix.Tasks.Mana.Replay do
  @shortdoc "Replays an exported history log against the code compiled now (Mana.Replay)"
  @moduledoc """
      mix mana.replay --log history.jsonl [--actor-resource MyApp.Accounts.User] [--skip-external] [--limit 500] [--json]

  Rebuilds every subject of the log (from `mix mana.history.export`) with
  the current code, inside transactions that are rolled back, and prints
  per feature how many came out the same, diverged, were refused or
  failed. Run it against a database that holds what the subjects refer to.
  `--actor-resource` loads each recorded actor by id, so policies and
  `^actor` apply; without it actions run unauthorized. Exits 1 when a
  subject diverged or failed.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: [log: :string, actor_resource: :string, skip_external: :boolean, limit: :integer, json: :boolean])
    Mix.Task.run("app.start")
    app = Mix.Project.config()[:app]

    actor =
      case opts[:actor_resource] do
        nil ->
          fn _ -> nil end

        name ->
          resource = name |> String.split(".") |> Module.safe_concat()

          fn id ->
            case id && Ash.get(resource, id, authorize?: false) do
              {:ok, actor} -> actor
              _ -> nil
            end
          end
      end

    report =
      opts
      |> Keyword.fetch!(:log)
      |> Mana.Replay.read()
      |> Mana.Replay.run(
        domains: Application.fetch_env!(app, :ash_domains),
        actor: actor,
        external: if(opts[:skip_external], do: :skip),
        limit: opts[:limit]
      )

    if opts[:json],
      do: Mix.shell().info(Jason.encode!(%{subjects: report.subjects, by_feature: report.by_feature, results: report.results}, pretty: true)),
      else: Mix.shell().info(Mana.Replay.format(report))

    if Enum.any?(report.results, &(&1.outcome in [:diverged, :failed])), do: exit({:shutdown, 1})
  end
end
