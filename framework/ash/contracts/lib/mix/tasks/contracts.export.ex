defmodule Mix.Tasks.Contracts.Export do
  use Mix.Task
  @shortdoc "Export a normalized JSON:API contract without starting the app"

  def run([modules, prefix, output]), do: export(modules, prefix, output, Contracts.OpenApi)

  def run([modules, prefix, output, modifier]) do
    Mix.Task.run("compile")
    module = Module.safe_concat(String.split(modifier, "."))

    unless Code.ensure_loaded?(module) and function_exported?(module, :modify, 3),
      do: Mix.raise("Contract modifier must export modify/3")

    export(modules, prefix, output, module)
  end

  def run(_),
    do: Mix.raise("Usage: mix contracts.export MyApp.Domain /api output.json [MyApp.OpenApi]")

  defp export(modules, prefix, output, modifier) do
    Mix.Task.run("compile")
    unless String.starts_with?(prefix, "/"), do: Mix.raise("Prefix must start with /")
    domains = Enum.map(String.split(modules, ","), &Module.safe_concat(String.split(&1, ".")))

    contract =
      AshJsonApi.OpenApi.spec(domains: domains, prefix: prefix)
      |> modifier.modify(nil, [])
      |> Jason.encode!(pretty: true)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output <> ".tmp", contract <> "\n")
    File.rename!(output <> ".tmp", output)
    Mix.shell().info("Exported contract to #{output}")
  end
end
