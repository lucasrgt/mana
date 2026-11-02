defmodule Mix.Tasks.Mana.Affordances do
  @shortdoc "Writes (or checks) affordances.json: what each actor is offered in each state"
  @moduledoc """
      mix mana.affordances [--out affordances.json] [--check]

  Explores the app with the explore module's options (see `mix
  mana.explore`; the seed is fixed, 1 unless configured) and writes the
  affordance lock (`Mana.Explore.Lock`). With `--check` it writes nothing:
  it prints what changed against the committed file, as sentences, and
  exits 1 when anything did.
  """
  use Mix.Task

  alias Mana.Explore.Lock
  alias Mix.Tasks.Mana.Explore, as: ExploreTask

  @impl true
  def run(args) do
    {cli, _} =
      OptionParser.parse!(args,
        strict: [out: :string, check: :boolean, runs: :integer, depth: :integer]
      )

    Mix.Task.run("app.start")
    path = cli[:out] || "affordances.json"
    {domains, opts} = ExploreTask.options(Keyword.take(cli, [:runs, :depth]))

    lock =
      domains |> Mana.Explore.run(Keyword.put(opts, :shrink, false)) |> Lock.build()

    if cli[:check] do
      committed = if File.exists?(path), do: path |> File.read!() |> Jason.decode!(), else: %{}

      case Lock.diff(committed, lock) do
        [] ->
          Mix.shell().info("#{path} is current")

        changes ->
          Mix.shell().info(
            "#{path} is stale; run mix mana.affordances:\n" <>
              Enum.map_join(changes, "\n", &"  #{&1}")
          )

          exit({:shutdown, 1})
      end
    else
      File.write!(path, Lock.encode(lock))
      Mix.shell().info("wrote #{path}")
    end
  end
end
