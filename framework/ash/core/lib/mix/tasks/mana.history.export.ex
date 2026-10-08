defmodule Mix.Tasks.Mana.History.Export do
  @shortdoc "Writes history entries as JSON lines for a data warehouse"
  @moduledoc """
  Every `Mana.History` entry of the app's logs since a moment, one JSON
  object per line, oldest first — the feed a warehouse loads on a schedule:

      mix mana.history.export --since 2026-10-01T00:00:00Z [--out history.jsonl]

  Redacted values stay `"[redacted]"`; personal fields never leave as
  plain values the history did not already keep.
  """
  use Mix.Task
  require Ash.Query

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [since: :string, out: :string])
    Mix.Task.run("app.start")
    {:ok, since, _} = DateTime.from_iso8601(opts[:since] || "1970-01-01T00:00:00Z")
    app = Mix.Project.config()[:app]

    lines =
      for domain <- Application.fetch_env!(app, :ash_domains),
          log <- Ash.Domain.Info.resources(domain),
          Mana.History.Log in Spark.extensions(log),
          entry <- log |> Ash.Query.filter(at >= ^since) |> Ash.Query.sort(at: :asc) |> Ash.read!(authorize?: false) do
        entry
        |> Map.take([:id, :subject_type, :subject_id, :action, :verb, :actor_id, :actor_kind, :via, :params, :before, :after, :outcome, :error, :summary, :at])
        |> Jason.encode!()
      end

    case opts[:out] do
      nil -> Enum.each(lines, &IO.puts/1)
      path -> File.write!(path, Enum.map(lines, &[&1, "\n"]))
    end

    Mix.shell().info("mana.history.export: #{length(lines)} entries")
  end
end
