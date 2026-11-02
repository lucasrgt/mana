defmodule Mana.Search do
  @moduledoc """
  Narrows a read by a free-text argument over string fields, ignoring case and
  treating `%`, `_` and `\\` as text: `prepare({Mana.Search, fields: [:name, :city]})`
  reads the `q` argument (or `argument:`). A blank text leaves the read alone.

  A `{:array, :string}` field matches when any element does (`EXISTS` over
  `unnest` on AshPostgres). A string inside an embedded resource is named
  by the embedded attribute and its field: `fields: [:name, services:
  :label]` (or `services: [:label, :note]`) matches when the field of the
  embedded value, or of any element of an embedded array, does — in the
  query on AshPostgres (`->>` over the `jsonb` value, `unnest` over the
  `jsonb[]` array). A field the embedded resource does not have raises at
  the read.
  On a data layer without `ilike` (ETS), and for embedded fields on any data
  layer but AshPostgres, every field is matched in memory.

  `unaccent: true` also ignores accents both ways (`Sao Joao` finds `São João`,
  `São João` finds `Sao Joao`), embedded fields included, with Postgres
  `unaccent` on the field and the text. It needs AshPostgres and the
  extension: add `"unaccent"` to the repo's `installed_extensions/0` and
  generate migrations (`mix ash.codegen`), which writes `CREATE EXTENSION IF
  NOT EXISTS "unaccent"`. On any other data layer the read raises, even with
  a blank text, instead of quietly keeping accents.
  """
  use Ash.Resource.Preparation
  alias Ash.Resource.Info
  require Ash.Expr
  require Ash.Query

  @impl true
  def init(opts) do
    if opts[:unaccent] in [nil, false, true] do
      with {:ok, fields} <- fields(opts[:fields]),
           do: {:ok, opts |> Keyword.put(:fields, fields) |> Keyword.put_new(:argument, :q)}
    else
      {:error, "`unaccent` must be true or false"}
    end
  end

  # Each searched string as `{attribute, nil}` or `{embedded attribute, field}`.
  defp fields([_ | _] = fields) do
    Enum.reduce_while(fields, {:ok, []}, fn
      field, {:ok, acc} when is_atom(field) ->
        {:cont, {:ok, acc ++ [{field, nil}]}}

      {field, inner}, {:ok, acc} when is_atom(field) and is_atom(inner) ->
        {:cont, {:ok, acc ++ [{field, inner}]}}

      {field, [_ | _] = inner}, {:ok, acc} when is_atom(field) ->
        if Enum.all?(inner, &is_atom/1),
          do: {:cont, {:ok, acc ++ Enum.map(inner, &{field, &1})}},
          else: {:halt, fields(nil)}

      _, _ ->
        {:halt, fields(nil)}
    end)
  end

  defp fields(_),
    do:
      {:error,
       "`fields` must name the string attributes to search, and an embedded one's fields as `services: :label`"}

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
          |> Enum.map(&match(how, shape(query.resource, &1), text))
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

  # How the field is stored: `:plain`, `:array`, or `{:embedded, field,
  # :one | :array}` for a field of an embedded value.
  defp shape(resource, {field, nil}) do
    case Info.attribute(resource, field) do
      %{type: {:array, _}} -> {field, :array}
      _ -> {field, :plain}
    end
  end

  defp shape(resource, {field, inner}) do
    attribute = Info.attribute(resource, field)

    unless attribute && Ash.Type.embedded_type?(attribute.type) &&
             Info.attribute(embedded(attribute.type), inner) do
      raise ArgumentError,
            "Mana.Search: #{inspect(resource)}.#{field} is not an embedded attribute with a field #{inspect(inner)}"
    end

    {field, {:embedded, inner, if(match?({:array, _}, attribute.type), do: :array, else: :one)}}
  end

  defp embedded({:array, type}), do: embedded(type)
  defp embedded(type), do: Ash.Type.get_type(type)

  defp match(:memory, {field, {:embedded, inner, _many}}, text),
    do:
      Ash.Expr.expr(
        fragment(&__MODULE__.contains?/3, ^String.downcase(text), ^Ash.Expr.ref(field), ^inner)
      )

  defp match(:memory, {field, _shape}, text),
    do:
      Ash.Expr.expr(
        fragment(&__MODULE__.contains?/2, ^String.downcase(text), ^Ash.Expr.ref(field))
      )

  defp match(:ilike, {_field, kind} = spec, text) when kind != :plain,
    do: match(:memory, spec, text)

  defp match(how, {field, :plain}, text) when how in [:postgres, :ilike],
    do: Ash.Expr.expr(ilike(^Ash.Expr.ref(field), ^pattern(text)))

  defp match(:postgres, {field, :array}, text),
    do:
      Ash.Expr.expr(
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS element(value) WHERE value ILIKE ?)",
          ^Ash.Expr.ref(field),
          ^pattern(text)
        )
      )

  defp match(:unaccent, {field, :plain}, text),
    do:
      Ash.Expr.expr(
        fragment("unaccent(?) ILIKE unaccent(?)", ^Ash.Expr.ref(field), ^pattern(text))
      )

  defp match(:unaccent, {field, :array}, text),
    do:
      Ash.Expr.expr(
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS element(value) WHERE unaccent(value) ILIKE unaccent(?))",
          ^Ash.Expr.ref(field),
          ^pattern(text)
        )
      )

  defp match(:postgres, {field, {:embedded, inner, :one}}, text),
    do:
      Ash.Expr.expr(
        fragment("(?->>?) ILIKE ?", ^Ash.Expr.ref(field), ^to_string(inner), ^pattern(text))
      )

  defp match(:unaccent, {field, {:embedded, inner, :one}}, text),
    do:
      Ash.Expr.expr(
        fragment(
          "unaccent(?->>?) ILIKE unaccent(?)",
          ^Ash.Expr.ref(field),
          ^to_string(inner),
          ^pattern(text)
        )
      )

  defp match(:postgres, {field, {:embedded, inner, :array}}, text),
    do:
      Ash.Expr.expr(
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS element(value) WHERE value->>? ILIKE ?)",
          ^Ash.Expr.ref(field),
          ^to_string(inner),
          ^pattern(text)
        )
      )

  defp match(:unaccent, {field, {:embedded, inner, :array}}, text),
    do:
      Ash.Expr.expr(
        fragment(
          "EXISTS (SELECT 1 FROM unnest(?) AS element(value) WHERE unaccent(value->>?) ILIKE unaccent(?))",
          ^Ash.Expr.ref(field),
          ^to_string(inner),
          ^pattern(text)
        )
      )

  defp pattern(text), do: "%" <> String.replace(text, ~r/([\\%_])/, "\\\\\\1") <> "%"

  @doc false
  def contains?(text, values) when is_list(values), do: Enum.any?(values, &contains?(text, &1))
  def contains?(_text, nil), do: false

  def contains?(text, value),
    do: value |> to_string() |> String.downcase() |> String.contains?(text)

  @doc false
  def contains?(text, values, inner) when is_list(values),
    do: Enum.any?(values, &contains?(text, &1, inner))

  def contains?(text, value, inner), do: contains?(text, Map.get(value, inner))
end
