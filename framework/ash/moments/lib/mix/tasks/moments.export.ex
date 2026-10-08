defmodule Mix.Tasks.Moments.Export do
  use Mix.Task
  @shortdoc "Export an Ash Moments declaration for the local Flutter bridge"
  def run([module, output]) do
    before = Moments.BackendGraph.snapshot()
    Mix.Task.run("compile")
    modules = Enum.map(String.split(module, ","), &Module.safe_concat(String.split(&1, ".")))
    opts = [source_root: output |> Path.expand() |> Path.dirname()]
    manifest = case modules do
      [single] -> Moments.Manifest.build(single, opts)
      many -> Moments.Manifest.build_many(many, opts)
    end
    manifest = Map.put(manifest, "backendGraph", Moments.BackendGraph.build(modules, manifest, output, before))
    contents = Jason.encode!(manifest, pretty: true) <> "\n"
    File.mkdir_p!(Path.dirname(output))
    File.write!(output <> ".tmp", contents)
    File.rename!(output <> ".tmp", output)
    Mix.shell().info("Exported #{map_size(manifest["moments"])} moments to #{output}")
  end

  def run(_), do: Mix.raise("Usage: mix moments.export MyApp.Domain output.json")
end
