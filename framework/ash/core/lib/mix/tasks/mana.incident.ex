defmodule Mix.Tasks.Mana.Incident do
  @shortdoc "Writes a record's history as an anonymized incident fixture (Mana.Incident)"
  @moduledoc """
      mix mana.incident booking:<id> [--at 2026-10-30T14:05:00Z] [--out priv/moments/incidents] [--role <user id>=host ...]

  Exports the record's history up to `--at` (default now), with the records
  it references, as a `mana.incident/1` fixture with every declared
  personal value and every person replaced (`Mana.Incident.export/4`), to
  `<out>/<type>-<at>.json`, and prints the recipe line that replays it.
  `--role` names a person's role; the rest are `person-1`, `person-2`, ...
  The export reads the logs with authorization off: run it where the
  operator may read production.
  """
  use Mix.Task

  @impl true
  def run(args) do
    {opts, subject} =
      OptionParser.parse!(args, strict: [at: :string, out: :string, role: :keep])

    {type, id} = subject(subject)
    Mix.Task.run("app.start")
    app = Mix.Project.config()[:app]
    at = at(opts[:at])

    incident =
      Mana.Incident.export(Application.fetch_env!(app, :ash_domains), type, id,
        at: at,
        roles: roles(Keyword.get_values(opts, :role))
      )

    dir = opts[:out] || "priv/moments/incidents"
    path = Path.join(dir, "#{type}-#{Calendar.strftime(at, "%Y%m%dT%H%M%SZ")}.json")
    File.mkdir_p!(dir)
    File.write!(path, Mana.Incident.encode(incident))

    actors = Enum.map_join(incident["roles"], ", ", &~s("#{&1}" => ...))

    Mix.shell().info("""
    mana.incident: #{length(incident["records"])} records → #{path}
    In a recipe (data_scope: true):
      {:ok, #{type}, _records} = Mana.Incident.replay("#{path}", domains, %{#{actors}})\
    """)
  end

  defp subject([subject]) do
    case String.split(subject, ":", parts: 2) do
      [type, id] when type != "" and id != "" -> {type, id}
      _ -> Mix.raise("expected <type>:<id>, got #{inspect(subject)}")
    end
  end

  defp subject(_), do: Mix.raise("usage: mix mana.incident <type>:<id> [--at <iso>] [--out dir]")

  defp at(nil), do: DateTime.utc_now()

  defp at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> Mix.raise("--at is not an ISO 8601 moment: #{inspect(text)}")
    end
  end

  defp roles(pairs) do
    Map.new(pairs, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [id, role] when id != "" and role != "" -> {id, role}
        _ -> Mix.raise("--role expects <user id>=<role>, got #{inspect(pair)}")
      end
    end)
  end
end
