defmodule ManaLint.Check.AshSeedOutsideSeeds do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [
      allowed_paths: ManaLint.Code.fixture_paths(),
      allowed_modules: [~r/(^|\.)Moments(\.|$)/]
    ],
    explanations: [
      check: """
      Flags `Ash.Seed.*` (`seed!`, `update!`, `upsert!`) outside tests, seeds,
      Moments recipes and support code.

      `Ash.Seed` writes straight to the data layer: no action runs, so no
      validation, policy, change, `Mana.History` entry or `Mana.Entity`
      announcement either. That is what a fixture wants and what production
      code must not do: a record changed this way skips the rules every other
      path enforces and leaves no trace.

      Instead, give the change an action of its own (an `update :prune` that
      sets what it must, with `authorize?: false` only where the caller is
      trusted) and call it with `Ash.update/3` or the domain's code interface.
      """,
      params: [
        allowed_paths: "Paths (regexes or substrings) where `Ash.Seed` belongs.",
        allowed_modules: "Modules (regexes or substrings of the name) where `Ash.Seed` belongs."
      ]
    ]

  alias ManaLint.Code

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Code.listed?(Params.get(params, :allowed_paths, __MODULE__), source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      allowed = Params.get(params, :allowed_modules, __MODULE__)

      for module <- source_file |> Code.ast() |> Code.modules(),
          not Code.listed?(allowed, module.name),
          node <- Code.module_nodes(module),
          Code.calls?(node, module, "Ash.Seed", :any),
          do: Code.issue(__MODULE__, issue_meta, node, message(Code.call(node, module)))
    end
  end

  defp message(call),
    do:
      "`#{Code.name(call)}` writes without an action: no validation, policy, History or announcement. " <>
        "Give the change an action and call it."
end
