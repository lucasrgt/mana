defmodule Mana.Upgrade do
  @moduledoc """
  Codemods that move an app's code to newer Mana idioms
  (`mix mana.upgrade <codemod> [paths]`).

  A codemod reads the files through Sourceror and edits only the source
  ranges it changes, so comments and the layout of everything else stay as
  written, and a second run finds nothing left to do. What it cannot rewrite
  safely it leaves untouched and reports as skipped, with the reason.
  """

  alias Mana.Upgrade.{TimedRules, VerbSteps}

  @codemods %{"verb_steps" => VerbSteps, "timed_rules" => TimedRules}

  @type sources :: %{Path.t() => String.t()}
  @type skip :: %{path: Path.t(), line: pos_integer(), reason: String.t()}

  @doc "The rewritten sources of the files it changed, and what it left alone and why."
  @callback rewrite(sources(), keyword()) :: {sources(), [skip()]}

  @doc "The codemods by name."
  def codemods, do: @codemods

  @doc """
  Runs `codemod` over the `.ex`/`.exs` files of `paths` (directories are
  walked, skipping `deps` and `_build`) without writing anything.
  """
  @spec run(module(), [Path.t()], keyword()) :: %{
          changed: [{Path.t(), String.t(), String.t()}],
          skipped: [skip()]
        }
  def run(codemod, paths, opts \\ []) do
    sources = Map.new(files(paths), &{&1, File.read!(&1)})
    {rewritten, skipped} = codemod.rewrite(sources, opts)

    %{
      changed:
        for(
          {path, text} <- Enum.sort(rewritten),
          text != sources[path],
          do: {path, sources[path], text}
        ),
      skipped: Enum.sort_by(skipped, &{&1.path, &1.line})
    }
  end

  @doc false
  def files(paths) do
    paths
    |> Enum.flat_map(&expand/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand(path) do
    cond do
      File.dir?(path) ->
        path
        |> Path.join("**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.reject(&built?(Path.relative_to(&1, path)))

      File.regular?(path) ->
        [path]

      true ->
        raise ArgumentError, "no such file or directory: #{path}"
    end
  end

  defp built?(path), do: path |> Path.split() |> Enum.any?(&(&1 in ["deps", "_build"]))
end
