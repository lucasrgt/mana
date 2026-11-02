defmodule Contracts.OpenApi do
  @moduledoc "OpenAPI 3.0 compatibility for the pinned AshJsonApi exporter."
  def modify(spec, _conn, _opts) do
    spec |> Jason.encode!() |> Jason.decode!() |> normalize()
  end

  def normalize(items) when is_list(items), do: Enum.map(items, &normalize/1)

  def normalize(value) when is_map(value) do
    value
    |> Map.new(fn {k, v} -> {k, normalize(v)} end)
    |> sparse_fieldsets()
    |> nullable()
    |> empty_includes()
    |> scalar_enum()
  end

  def normalize(value), do: value

  # JSON:API sparse fieldsets are a resource-name -> comma-separated string map.
  # Explicit map values avoid dart-dio's inline object/map alias conflict.
  defp sparse_fieldsets(%{"in" => "query", "name" => "fields", "schema" => schema} = value) do
    schema =
      schema
      |> Map.delete("properties")
      |> Map.put("additionalProperties", %{"type" => "string"})

    Map.put(value, "schema", schema)
  end

  defp sparse_fieldsets(value), do: value

  defp nullable(%{"anyOf" => [%{"type" => _} = base, %{"type" => "null"}]} = value),
    do: value |> Map.delete("anyOf") |> Map.merge(base) |> Map.put("nullable", true)

  defp nullable(value), do: value

  # No includable relationships: preserve an empty array, not an open union.
  defp empty_includes(%{"type" => "array", "items" => %{"oneOf" => []}} = value),
    do: value |> Map.put("items", %{"type" => "object"}) |> Map.put("maxItems", 0)

  defp empty_includes(value), do: value

  defp scalar_enum(%{"enum" => [_ | _] = values} = value) do
    cond do
      # `{"success": true}` of actions without a return: generators turn a
      # boolean enum into a string enum that cannot decode the JSON boolean.
      Enum.all?(values, &is_boolean/1) ->
        value |> Map.delete("enum") |> Map.put("type", "boolean")

      !Map.has_key?(value, "type") and Enum.all?(values, &is_binary/1) ->
        Map.put(value, "type", "string")

      true ->
        value
    end
  end

  defp scalar_enum(value), do: value
end
