defmodule Mix.Tasks.Mana.Explore do
  @shortdoc "Explores the app's state space for broken promises (Mana.Explore)"
  @moduledoc """
      mix mana.explore [--runs 50] [--depth 10] [--seed 1] [--resource MyApp.Booking ...] [--save explore] [--json]

  Runs `Mana.Explore` with the options the app's explore module answers —
  `config :mana_core, :explore, MyApp.Explore`, a module with `options/0`
  (`setup`, `reset`, `domains`, `resources`, `skip_rules`, `generators`, …;
  `domains` defaults to the app's `ash_domains`). Command-line options win.
  Prints the report (or its AVP verdict with `--json`), writes each
  violation's trace under `--save`, and exits 1 when a property broke.
  """
  use Mix.Task

  @switches [runs: :integer, depth: :integer, seed: :integer, resource: :keep, save: :string, json: :boolean]

  @impl true
  def run(args) do
    {cli, _} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("app.start")
    {domains, opts} = options(cli)
    report = Mana.Explore.run(domains, opts)

    if cli[:json] do
      Mix.shell().info(Jason.encode!(Mana.Explore.verdict("explore", report), pretty: true))
    else
      Mix.shell().info(Mana.Explore.format(report))
    end

    if dir = cli[:save] do
      for violation <- report.violations, do: Mix.shell().info("saved #{Mana.Explore.save(violation, dir)}")
    end

    if report.violations != [], do: exit({:shutdown, 1})
  end

  @doc false
  def options(cli) do
    app = Mix.Project.config()[:app]
    configured = case Application.get_env(:mana_core, :explore) do
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
