defmodule Mana.Search do
  @moduledoc """
  Narrows a read by a free-text argument over string fields, ignoring case and
  treating `%`, `_` and `\\` as text: `prepare({Mana.Search, fields: [:name, :city]})`
  reads the `q` argument (or `argument:`). A blank text leaves the read alone.
  """
  use Ash.Resource.Preparation
  require Ash.Expr
  require Ash.Query

  @impl true
  def init(opts) do
    if is_list(opts[:fields]) and opts[:fields] != [],
      do: {:ok, Keyword.put_new(opts, :argument, :q)},
      else: {:error, "`fields` must name the string attributes to search"}
  end

  @impl true
  def prepare(query, opts, _) do
    case String.trim(Ash.Query.get_argument(query, opts[:argument]) || "") do
      "" ->
        query

      text ->
        pattern = "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"

        matches =
          opts[:fields]
          |> Enum.map(&Ash.Expr.expr(ilike(^Ash.Expr.ref(&1), ^pattern)))
          |> Enum.reduce(&Ash.Expr.expr(^&2 or ^&1))

        Ash.Query.filter(query, ^matches)
    end
  end
end
