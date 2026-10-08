defmodule Contracts.OpenApi do
  @moduledoc "OpenAPI 3.0 compatibility for the pinned AshJsonApi exporter."
  def modify(spec, _conn, _opts) do
    spec |> Jason.encode!() |> Jason.decode!() |> normalize()
  end

  def normalize(items) when is_list(items), do: Enum.map(items, &normalize/1)

  def normalize(value) when is_map(value) do
    value = Map.new(value, fn {k, v} -> {k, normalize(v)} end)

    value =
      case value do
        %{"in" => "query", "name" => "fields", "schema" => schema} ->
          # JSON:API sparse fieldsets are a resource-name -> comma-separated string map.
          # Explicit map values avoid dart-dio's inline object/map alias conflict.
          schema =
            schema
            |> Map.delete("properties")
            |> Map.put("additionalProperties", %{"type" => "string"})

          Map.put(value, "schema", schema)

        _ ->
          value
      end

    value =
      case value do
        %{"anyOf" => [base, %{"type" => "null"}]} when is_map(base) ->
          if Map.has_key?(base, "type") do
            value |> Map.delete("anyOf") |> Map.merge(base) |> Map.put("nullable", true)
          else
            value
          end

        _ ->
          value
      end

    value =
      case value do
        %{"type" => "array", "items" => %{"oneOf" => []}} ->
          # No includable relationships: preserve an empty array, not an open union.
          value |> Map.put("items", %{"type" => "object"}) |> Map.put("maxItems", 0)

        _ ->
          value
      end

    case value do
      %{"enum" => values} when is_list(values) and values != [] ->
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

      _ ->
        value
    end
  end

  def normalize(value), do: value
end
