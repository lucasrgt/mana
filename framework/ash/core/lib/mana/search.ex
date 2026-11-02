defmodule Mana.Search do
  @moduledoc """
  Narrows a read by a free-text argument over string fields, ignoring case and
  treating `%`, `_` and `\\` as text: `prepare({Mana.Search, fields: [:name, :city]})`
  reads the `q` argument (or `argument:`). A blank text leaves the read alone.

  A `{:array, :string}` field matches when any element does (`EXISTS` over
  `unnest` on AshPostgres). On a data layer without `ilike` (ETS) every field
  is matched in memory.

  `unaccent: true` also ignores accents both ways (`Sao Joao` finds `São João`,
  `São João` finds `Sao Joao`), with Postgres `unaccent` on the field and the
  text. It needs AshPostgres and the extension: add `"unaccent"` to the repo's
  `installed_extensions/0` and generate migrations (`mix ash.codegen`), which
  writes `CREATE EXTENSION IF NOT EXISTS "unaccent"`. On any other data layer
  the read raises, even with a blank text, instead of quietly keeping accents.
  """
  use Ash.Resource.Preparation
  alias Ash.Resource.Info
  require Ash.Expr
  require Ash.Query

  @impl true
  def init(opts) do
    cond do
      not is_list(opts[:fields]) or opts[:fields] == [] ->
        {:error, "`fields` must name the string attributes to search"}

      opts[:unaccent] not in [nil, false, true] ->
        {:error, "`unaccent` must be true or false"}

      true ->
        {:ok, Keyword.put_new(opts, :argument, :q)}
    end
  end

  @impl true
  def prepare(query, opts, _) do
    data_layer = Ash.DataLayer.data_layer(query.resource)
    unaccent? = opts[:unaccent] == true

    if unaccent? and data_layer != AshPostgres.DataLayer do
      raise ArgumentError,
            "Mana.Search `unaccent: true` needs AshPostgres with the unaccent extension; " <>
              "#{inspect(query.resource)} uses #{inspect(data_layer)}"
    end

    case String.trim(Ash.Query.get_argument(query, opts[:argument]) || "") do
      "" ->
        query

      text ->
        how = how(query.resource, data_layer, unaccent?)

        matches =
          opts[:fields]
          |> Enum.map(&match(how, &1, array?(query.resource, &1), text))
          |> Enum.reduce(&Ash.Expr.expr(^&2 or ^&1))

        Ash.Query.filter(query, ^matches)
    end
  end

  defp how(_resource, AshPostgres.DataLayer, true), do: :unaccent
  defp how(_resource, AshPostgres.DataLayer, false), do: :postgres

  defp how(resource, _data_layer, false) do
    if Enum.any?(Ash.DataLayer.functions(resource), &(&1.name() == :ilike)),
      do: :ilike,
      else: :memory
  end

  defp array?(resource, field),
    do: match?(%{type: {:array, _}}, Info.attribute(resource, field))

  defp match(:memory, field, _array?, text),
    do:
      Ash.Expr.expr(
        fragment(&__MODULE__.contains?/2, ^String.downcase(text), ^Ash.Expr.ref(field))
      )

  defp match(how, field, false, text) when how in [:postgres, :ilike],
    do: Ash.Expr.expr(ilike(^Ash.Expr.ref(field), ^pattern(text)))

  defp match(:ilike, field, true, text), do: match(:memory, field, true, text)

  defp match(:postgres, field, true, text),
    do:
      Ash.Expr.expr(
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS element(value) WHERE value ILIKE ?)",
          ^Ash.Expr.ref(field),
          ^pattern(text)
        )
      )

  defp match(:unaccent, field, false, text),
    do:
      Ash.Expr.expr(
        fragment("unaccent(?) ILIKE unaccent(?)", ^Ash.Expr.ref(field), ^pattern(text))
      )

  defp match(:unaccent, field, true, text),
    do:
      Ash.Expr.expr(
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS element(value) WHERE unaccent(value) ILIKE unaccent(?))",
          ^Ash.Expr.ref(field),
          ^pattern(text)
        )
      )

  defp pattern(text), do: "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"

  @doc false
  def contains?(text, values) when is_list(values), do: Enum.any?(values, &contains?(text, &1))
  def contains?(_text, nil), do: false

  def contains?(text, value),
    do: value |> to_string() |> String.downcase() |> String.contains?(text)
end
