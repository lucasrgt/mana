defmodule Moments.BackendGraph do
  @moduledoc "Optional, portable compiled dependency evidence for conservative impact planning."

  def snapshot do
    paths = Mix.Project.config() |> Keyword.get(:elixirc_paths, ["lib"]) |> Enum.sort()
    files = paths |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex"))) |> Enum.uniq() |> Enum.sort()
    if length(files) > 20_000, do: raise(ArgumentError, "backend graph file bound exceeded")
    %{paths: paths, files: Map.new(files, &{&1, digest(&1)})}
  rescue
    _ -> nil
  end

  def build(modules, manifest, output, before) do
    try do
      unless is_map(before) and before == snapshot(), do: raise(ArgumentError, "sources changed during compilation")
      temp = Path.join(System.tmp_dir!(), "mana-xref-#{Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)}.dot")
      graph = try do
        Mix.Task.reenable("xref")
        Mix.Task.run("xref", ["graph", "--format", "dot", "--output", temp])
        if File.stat!(temp).size > 16 * 1024 * 1024, do: raise(ArgumentError, "xref graph exceeds bound")
        parse_dot!(File.read!(temp))
      after
        File.rm(temp)
      end
      unless Enum.sort(Map.keys(graph)) == Enum.sort(Map.keys(before.files)),
        do: raise(ArgumentError, "xref source inventory is incomplete")
      root = output |> Path.expand() |> Path.dirname()
      portable = fn file -> Path.relative_to(Path.expand(file), root, force: true) end
      domain_roots = Map.new(modules, fn domain ->
        resources = Ash.Domain.Info.resources(domain)
        # Declaration-only domains cannot establish ownership of an external API.
        roots = if resources == [], do: [], else: Enum.map([domain | resources], fn module ->
          file = module.module_info(:compile)[:source] |> to_string() |> Path.relative_to(File.cwd!())
          unless Map.has_key?(graph, file), do: raise(ArgumentError, "resource is outside compiled project")
          portable.(file)
        end)
        {inspect(domain), Enum.uniq(roots) |> Enum.sort()}
      end)
      roots = Map.new(manifest["moments"], fn {name, scene} ->
        {name, Map.fetch!(domain_roots, scene["source"]["module"])}
      end)
      files = Map.new(graph, fn {file, dependencies} ->
        {portable.(file), %{"sha256" => Map.fetch!(before.files, file),
          "dependencies" => Enum.map(dependencies, portable) |> Enum.sort()}}
      end)
      unless before == snapshot(), do: raise(ArgumentError, "sources changed during export")
      %{"version" => 1, "status" => "available", "engine" => "mix-xref+ash-resources",
        "elixir" => System.version(), "environment" => to_string(Mix.env()),
        "project" => portable.("."), "sourcePaths" => before.paths,
        "files" => files, "roots" => roots}
    rescue
      _ -> %{"version" => 1, "status" => "unavailable"}
    end
  end

  # Parse only Mix's documented DOT output, never evaluate it. An unsupported
  # format disables precision; compilation/export of Moments still succeeds.
  def parse_dot!(dot) do
    lines = dot |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)
    unless hd(lines) == "digraph \"xref graph\" {" and List.last(lines) == "}",
      do: raise(ArgumentError, "unsupported xref graph")
    Enum.slice(lines, 1, length(lines) - 2)
    |> Enum.reduce(%{}, fn line, graph ->
      case Regex.run(~r/^"([^"\\]+)"(?: -> "([^"\\]+)"(?: \[label="\((?:compile|export)\)"\])?)?$/, line) do
        [_, file] -> Map.put_new(graph, file, [])
        [_, file, dependency] ->
          graph |> Map.put_new(dependency, []) |> Map.update(file, [dependency], &[dependency | &1])
        _ -> raise(ArgumentError, "unsupported xref graph entry")
      end
    end)
    |> Map.new(fn {file, deps} -> {file, Enum.uniq(deps) |> Enum.sort()} end)
  end

  defp digest(file) do
    if File.stat!(file).size > 2 * 1024 * 1024, do: raise(ArgumentError, "backend source exceeds bound")
    :crypto.hash(:sha256, File.read!(file)) |> Base.encode16(case: :lower)
  end
end
