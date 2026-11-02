defmodule Mix.Tasks.Mana.Upgrade do
  @shortdoc "Rewrites an app's code to newer Mana idioms"
  @moduledoc """
      mix mana.upgrade <codemod> [paths...] [--dry-run] [--mapping file.json]

  Runs a codemod of `Mana.Upgrade` over `paths` (files or directories;
  `lib` by default) and writes the files it changes; `--dry-run` prints the
  diff instead. What a codemod leaves untouched is printed as `skipped`.

    * `verb_steps` — Moments steps tapping a key a `VerbGate` places become
      `verb:` steps (`Mana.Upgrade.VerbSteps`); needs `--mapping`, which
      `mana upgrade verb-steps` writes from the Flutter apps.
    * `timed_rules` — reconcile rules whose `holds:` only compares a
      timestamp plus a duration with now become `within:`/`since:`
      (`Mana.Upgrade.TimedRules`).
  """
  use Mix.Task

  alias Mana.Upgrade
  alias Mana.Upgrade.Diff

  @impl Mix.Task
  def run(args) do
    {options, rest} = OptionParser.parse!(args, strict: [dry_run: :boolean, mapping: :string])

    {name, paths} =
      case rest do
        [name | paths] -> {name, if(paths == [], do: ["lib"], else: paths)}
        [] -> Mix.raise(usage())
      end

    codemod =
      Map.get(Upgrade.codemods(), name) || Mix.raise("unknown codemod #{name}; " <> usage())

    report = Upgrade.run(codemod, paths, codemod_options(name, options))
    Enum.each(report.changed, &apply_change(&1, options[:dry_run]))

    for skip <- report.skipped,
        do: Mix.shell().info("skipped #{skip.path}:#{skip.line}: #{skip.reason}")

    Mix.shell().info(
      "#{name}: #{length(report.changed)} file(s) #{if options[:dry_run], do: "to change", else: "changed"}, " <>
        "#{length(report.skipped)} skipped"
    )
  end

  defp codemod_options("verb_steps", options) do
    path =
      options[:mapping] ||
        Mix.raise("verb_steps needs --mapping <file> (mana upgrade verb-steps writes it)")

    [mapping: path |> File.read!() |> JSON.decode!()]
  end

  defp codemod_options(_, _), do: []

  defp apply_change({path, before, after_}, true),
    do: Mix.shell().info(Diff.unified(path, before, after_))

  defp apply_change({path, _, after_}, _) do
    File.write!(path, after_)
    Mix.shell().info("rewrote #{path}")
  end

  defp usage,
    do:
      "use mix mana.upgrade <#{Enum.join(Map.keys(Upgrade.codemods()), "|")}> [paths] [--dry-run]"
end
