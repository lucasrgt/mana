defmodule Mana.Upgrade.Source do
  @moduledoc false
  # Reading Sourceror's AST: literals arrive wrapped in `{:__block__, meta,
  # [literal]}` (so they can carry comments), keyword keys included.

  @doc "The AST of `source`, or `:error` when it does not parse."
  def parse(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, _} -> :error
    end
  end

  @doc "The literal a node wraps, or the node."
  def literal({:__block__, _, [value]}) when not is_tuple(value) or tuple_size(value) == 2,
    do: value

  def literal(node), do: node

  @doc "The statements of a body: a block's, or the one expression."
  def statements({:__block__, _, [_ | _] = body} = node) do
    if literal(node) == node, do: body, else: [node]
  end

  def statements(nil), do: []
  def statements(node), do: [node]

  @doc "The body of a `do` block among a call's arguments, or nil."
  def do_body(args) when is_list(args) do
    Enum.find_value(args, fn
      [{key, body} | _] -> if literal(key) == :do, do: body
      _ -> nil
    end)
  end

  @doc "The calls named `name` among `statements`."
  def calls(statements, name),
    do: for({^name, _, args} = call <- statements, is_list(args), do: call)

  @doc "The `{key, value}` pairs of a call's keyword arguments, keys unwrapped."
  def keywords(args) do
    for list <- args, is_list(list), {key, value} <- list, is_atom(literal(key)) do
      {literal(key), key, value}
    end
  end

  @doc "A patch replacing the text from `first`'s start to `last`'s end."
  def replace(first, last, change) do
    %Sourceror.Patch{
      range: %{start: Sourceror.get_range(first).start, end: Sourceror.get_range(last).end},
      change: change
    }
  end

  @doc "The line a node starts on."
  def line(node), do: Sourceror.get_range(node).start[:line]

  @doc """
  Each source rewritten by `fun`, which answers a parsed file with
  `{:patch, patch}` and `{:skip, %{line:, reason:}}`; the skips, with their path.
  """
  def edit(sources, fun) do
    Enum.reduce(sources, {%{}, []}, fn {path, source}, {rewritten, skipped} ->
      {text, skips} = edit_file(source, fun)

      {if(text, do: Map.put(rewritten, path, text), else: rewritten),
       skipped ++ Enum.map(skips, &Map.put(&1, :path, path))}
    end)
  end

  defp edit_file(source, fun) do
    case parse(source) do
      {:ok, ast} ->
        results = fun.(ast)

        {patch(source, for({:patch, patch} <- results, do: patch)),
         for({:skip, skip} <- results, do: skip)}

      :error ->
        {nil, [%{line: 1, reason: "does not parse"}]}
    end
  end

  defp patch(source, []), do: source
  defp patch(source, patches), do: Sourceror.patch_string(source, patches)
end
