defmodule Mix.Tasks.Mana.Advance do
  @shortdoc "Runs the deadlines and stuck-flow checks due within a duration"
  @moduledoc """
      mix mana.advance 3d

  Performs now the `Mana.Entity` deadline and `Mana.Flow` stuck-check jobs
  that would come due within the duration (`Mana.Intervene.advance/2`) and
  prints what ran. For development and test databases only.
  """
  use Mix.Task

  @impl true
  def run([duration | _]) do
    if Mix.env() == :prod, do: Mix.raise("mana.advance changes data as if time passed; not in production")
    Mix.Task.run("app.start")
    [repo | _] = Application.fetch_env!(Mix.Project.config()[:app], :ecto_repos)

    for job <- Mana.Intervene.advance(repo, Mana.Intervene.parse(duration)) do
      Mix.shell().info("#{job.worker} #{inspect(job.args)} (due #{job.due}) → #{job.result}")
    end
  end
end
