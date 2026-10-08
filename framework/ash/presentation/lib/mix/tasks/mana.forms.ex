defmodule Mix.Tasks.Mana.Forms do
  use Mix.Task
  @shortdoc "Export the Dart form compilation for the host publisher"
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [api_spec: :string, api_package: :string])

    unless invalid == [] && length(positional) == 2,
      do: Mix.raise("Use generate-forms.mjs with resource and output")

    [module, output] = positional
    Mix.Task.run("compile", ["--warnings-as-errors"])
    resource = Module.safe_concat(String.split(module, "."))
    spec = if opts[:api_spec], do: opts[:api_spec] |> File.read!() |> Jason.decode!()

    contract =
      Mana.Presentation.Contract.build(resource, api_spec: spec, api_package: opts[:api_package])

    compiled = %{contract: contract, dart: Mana.Presentation.Dart.render(contract)}
    File.write!(output, Jason.encode!(compiled) <> "\n", [:exclusive])
    Mix.shell().info("Compiled #{length(contract.forms)} forms from #{module}")
  end
end
