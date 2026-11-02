defmodule Mana.Upgrade.Diff do
  @moduledoc false
  # A unified diff (three lines of context), enough to review a codemod's
  # change before writing it.

  @context 3

  def unified(path, before, after_) do
    ops = numbered(List.myers_difference(lines(before), lines(after_)))

    hunks =
      ops
      |> Enum.with_index()
      |> Enum.reject(fn {{kind, _, _, _}, _} -> kind == :eq end)
      |> Enum.map(fn {_, index} ->
        {max(index - @context, 0), min(index + @context, length(ops) - 1)}
      end)
      |> merge()

    Enum.join(["--- #{path}", "+++ #{path}" | Enum.flat_map(hunks, &hunk(ops, &1))], "\n") <> "\n"
  end

  defp lines(text), do: String.split(text, "\n")

  # Each line as {kind, text, old line, new line}: the line numbers it sits at.
  defp numbered(edits) do
    {ops, _} =
      Enum.flat_map_reduce(edits, {1, 1}, fn {kind, lines}, at ->
        Enum.map_reduce(lines, at, fn line, {old, new} ->
          {{kind, line, old, new}, advance(kind, old, new)}
        end)
      end)

    ops
  end

  defp advance(:eq, old, new), do: {old + 1, new + 1}
  defp advance(:del, old, new), do: {old + 1, new}
  defp advance(:ins, old, new), do: {old, new + 1}

  defp merge(ranges) do
    ranges
    |> Enum.reduce([], fn
      {from, to}, [{first, last} | rest] when from <= last + 1 -> [{first, max(to, last)} | rest]
      range, merged -> [range | merged]
    end)
    |> Enum.reverse()
  end

  defp hunk(ops, {from, to}) do
    slice = Enum.slice(ops, from..to)
    [{_, _, old, new} | _] = slice
    olds = Enum.count(slice, &(elem(&1, 0) != :ins))
    news = Enum.count(slice, &(elem(&1, 0) != :del))

    ["@@ -#{start(old, olds)},#{olds} +#{start(new, news)},#{news} @@" | Enum.map(slice, &line/1)]
  end

  # An empty side is numbered by the line before it, as diff(1) does.
  defp start(line, 0), do: line - 1
  defp start(line, _), do: line

  defp line({:eq, text, _, _}), do: " " <> text
  defp line({:del, text, _, _}), do: "-" <> text
  defp line({:ins, text, _, _}), do: "+" <> text
end
