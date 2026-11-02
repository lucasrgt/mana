defmodule Mix.Tasks.Mana.Explore do
  @shortdoc "Explores the app's state space for broken promises (Mana.Explore)"
  @moduledoc """
      mix mana.explore [--runs 50] [--depth 10] [--seed 1] [--resource MyApp.Booking ...] [--save <name> [--out priv/moments/explorations]] [--json]

  Runs `Mana.Explore` with the options the app's explore module answers —
  `config :mana_core, :explore, MyApp.Explore`, a module with `options/0`
  (`setup`, `reset`, `domains`, `resources`, `skip_rules`, `generators`, …;
  `domains` defaults to the app's `ash_domains`). Command-line options win.
  Prints the report (or its AVP verdict with `--json`) and exits 1 when a
  property broke.

  `--save <name>` writes each violation's shrunk trace as a Moment:
  `<out>/<name>.json`, the next ones `<name>-2.json`, `<name>-3.json`, ….
  A `moments` section declaring `explorations "<out>"` exports them at
  `moments sync`; each fails while its property breaks and passes once it
  holds. A name already saved there is refused before anything runs.
  """
  use Mix.Task

  @switches [
    runs: :integer,
    depth: :integer,
    seed: :integer,
    resource: :keep,
    save: :string,
    out: :string,
    json: :boolean
  ]

  @default_out "priv/moments/explorations"

  @impl true
  def run(args) do
    {cli, _} = OptionParser.parse!(args, strict: @switches)
    save = cli[:save] && saving!(cli[:save], cli[:out] || @default_out)
    Mix.Task.run("app.start")
    {domains, opts} = options(cli)
    report = Mana.Explore.run(domains, opts)

    if cli[:json] do
      Mix.shell().info(Jason.encode!(Mana.Explore.verdict("explore", report), pretty: true))
    else
      Mix.shell().info(Mana.Explore.format(report))
    end

    if save, do: save_all(report.violations, save)
    if report.violations != [], do: exit({:shutdown, 1})
  end

  # Moment names are dashed (Moments.Manifest); the file is named the same,
  # so the Moment and its trace are found by one name.
  defp saving!(name, dir) do
    unless Regex.match?(~r/^[a-z][a-z0-9_-]*$/, name),
      do: Mix.raise("--save takes a Moment name: lowercase letters, digits, - and _")

    name = String.replace(name, "_", "-")
    unsaved!(dir, name)
    {name, dir}
  end

  defp unsaved!(dir, name) do
    path = Path.join(dir, "#{name}.json")
    if File.exists?(path), do: Mix.raise("#{path} is saved already; choose another --save name")
  end

  defp save_all(violations, {name, dir}) do
    named =
      for index <- 1..length(violations)//1,
          do: if(index == 1, do: name, else: "#{name}-#{index}")

    Enum.each(named, &unsaved!(dir, &1))

    for {violation, named} <- Enum.zip(violations, named) do
      path = Mana.Explore.save(violation, dir, named)
      Mix.shell().info("saved Moment #{named}: #{path}")
    end
  end

  @doc false
  def options(cli) do
    app = Mix.Project.config()[:app]

    configured =
      case Application.get_env(:mana_core, :explore) do
        nil -> []
        module -> module.options()
      end

    domains = configured[:domains] || Application.fetch_env!(app, :ash_domains)

    resources =
      case Keyword.get_values(cli, :resource) do
        [] -> configured[:resources]
        names -> Enum.map(names, &(&1 |> String.split(".") |> Module.safe_concat()))
      end

    opts =
      configured
      |> Keyword.drop([:domains])
      |> Keyword.merge(Keyword.take(cli, [:runs, :depth, :seed]))
      |> then(&if(resources, do: Keyword.put(&1, :resources, resources), else: &1))
      |> Keyword.put_new(:seed, 1)

    {domains, opts}
  end
end
