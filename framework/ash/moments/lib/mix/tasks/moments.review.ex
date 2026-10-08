defmodule Mix.Tasks.Moments.Review do
  use Mix.Task
  @shortdoc "Plan a local architectural review of one compiled Ash action, without running it"

  def run([resource, action, output]) do
    before = Moments.BackendGraph.snapshot()
    Mix.Task.run("compile")

    unless before && before == Moments.BackendGraph.snapshot(),
      do: Mix.raise("Sources changed during compilation; run the planner again")

    module = Module.safe_concat(String.split(resource, "."))
    unless Code.ensure_loaded?(module), do: Mix.raise("Resource module is unavailable")
    plan = Moments.ActionReview.build(module, action)

    unless before == Moments.BackendGraph.snapshot(),
      do: Mix.raise("Sources changed during planning; run the planner again")

    plan =
      Map.put(plan, :compilation, %{
        environment: to_string(Mix.env()),
        elixir: System.version(),
        source_hashes: before.files,
        scope:
          "Current project source snapshot; dependency implementations and runtime not verified"
      })

    contents = Jason.encode!(plan, pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(output))
    temp = output <> ".#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}.tmp"
    File.write!(temp, contents, [:exclusive])

    try do
      File.chmod!(temp, 0o600)
      File.rename!(temp, output)
    after
      File.rm(temp)
    end

    Mix.shell().info(
      "Planned #{resource}.#{action}; no action or review executed. Report: #{output}"
    )
  end

  def run(_), do: Mix.raise("Usage: mix moments.review MyApp.Resource action output.json")
end
