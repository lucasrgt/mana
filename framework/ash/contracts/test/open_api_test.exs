defmodule Contracts.OpenApiTest do
  use ExUnit.Case, async: true

  alias Contracts.OpenApi

  describe "normalize" do
    test "a sparse fieldset becomes a map of comma-separated strings" do
      parameter = %{
        "in" => "query",
        "name" => "fields",
        "style" => "deepObject",
        "schema" => %{
          "type" => "object",
          "additionalProperties" => true,
          "properties" => %{"note" => %{"type" => "string"}}
        }
      }

      assert OpenApi.normalize(parameter)["schema"] == %{
               "type" => "object",
               "additionalProperties" => %{"type" => "string"}
             }

      for other <- [%{parameter | "in" => "path"}, %{parameter | "name" => "filter"}] do
        assert OpenApi.normalize(other) == other
      end
    end

    test "a scalar-or-null union becomes the scalar, nullable, keeping its siblings" do
      value = %{
        "description" => "Due date.",
        "anyOf" => [%{"type" => "string", "format" => "date-time"}, %{"type" => "null"}]
      }

      assert OpenApi.normalize(value) == %{
               "description" => "Due date.",
               "type" => "string",
               "format" => "date-time",
               "nullable" => true
             }
    end

    test "other unions are kept" do
      for value <- [
            %{"anyOf" => [%{"type" => "null"}, %{"type" => "string"}]},
            %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}]},
            %{"anyOf" => [%{"type" => "string"}, %{"type" => "integer"}, %{"type" => "null"}]},
            %{"anyOf" => [%{"$ref" => "#/components/schemas/Note"}, %{"type" => "null"}]}
          ] do
        assert OpenApi.normalize(value) == value
      end
    end

    test "an array of no possible items stays an empty array" do
      assert OpenApi.normalize(%{"type" => "array", "items" => %{"oneOf" => []}}) == %{
               "type" => "array",
               "items" => %{"type" => "object"},
               "maxItems" => 0
             }

      items = %{"type" => "array", "items" => %{"oneOf" => [%{"type" => "string"}]}}
      assert OpenApi.normalize(items) == items
    end

    test "a boolean enum is a boolean; an untyped string enum gets its type" do
      assert OpenApi.normalize(%{"enum" => [true]}) == %{"type" => "boolean"}
      assert OpenApi.normalize(%{"enum" => [true, false]}) == %{"type" => "boolean"}
      assert OpenApi.normalize(%{"enum" => ["note"]}) == %{"enum" => ["note"], "type" => "string"}

      for kept <- [
            %{"enum" => ["a"], "type" => "string"},
            %{"enum" => [1, 2], "type" => "integer"},
            %{"enum" => ["a", 1]},
            %{"enum" => []}
          ] do
        assert OpenApi.normalize(kept) == kept
      end
    end

    test "rules apply at every depth, after the children are normalized" do
      nested = %{
        "paths" => [
          %{"schema" => %{"anyOf" => [%{"enum" => ["a", "b"]}, %{"type" => "null"}]}}
        ]
      }

      assert OpenApi.normalize(nested) == %{
               "paths" => [
                 %{"schema" => %{"enum" => ["a", "b"], "type" => "string", "nullable" => true}}
               ]
             }

      assert OpenApi.normalize("text") == "text"
      assert OpenApi.normalize(nil) == nil
    end
  end

  test "modify turns the exporter's structs into plain JSON, then normalizes it" do
    schema = %OpenApiSpex.Schema{
      anyOf: [%OpenApiSpex.Schema{type: :integer}, %OpenApiSpex.Schema{type: :null}]
    }

    spec = %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{title: "Notes", version: "1"},
      paths: %{},
      components: %OpenApiSpex.Components{schemas: %{"Count" => schema}}
    }

    assert %{"info" => %{"title" => "Notes"}, "components" => %{"schemas" => schemas}} =
             OpenApi.modify(spec, nil, [])

    assert schemas == %{"Count" => %{"type" => "integer", "nullable" => true}}
  end

  describe "on the pinned AshJsonApi export" do
    setup do
      spec = AshJsonApi.OpenApi.spec(domains: [ContractsTest.Notes], prefix: "/api")
      %{contract: OpenApi.modify(spec, nil, [])}
    end

    defp nodes(value) when is_map(value), do: [value | Enum.flat_map(Map.values(value), &nodes/1)]
    defp nodes(value) when is_list(value), do: Enum.flat_map(value, &nodes/1)
    defp nodes(_value), do: []

    test "no shape the Dart generator misreads is left", %{contract: contract} do
      all = nodes(contract)

      refute Enum.any?(all, &match?(%{"anyOf" => [_, %{"type" => "null"}]}, &1))
      refute Enum.any?(all, &match?(%{"oneOf" => []}, &1))
      refute Enum.any?(all, &match?(%{"enum" => [b | _]} when is_boolean(b), &1))
      assert Enum.all?(for(%{"enum" => _} = e <- all, do: e), &Map.has_key?(&1, "type"))

      fields = for %{"in" => "query", "name" => "fields"} = p <- all, do: p["schema"]
      assert fields != []
      assert Enum.all?(fields, &(&1["additionalProperties"] == %{"type" => "string"}))
      refute Enum.any?(fields, &Map.has_key?(&1, "properties"))
    end

    test "attributes read as typed, nullable scalars", %{contract: contract} do
      attributes =
        contract["components"]["schemas"]["note"]["properties"]["attributes"]["properties"]

      assert %{"type" => "string", "nullable" => true} = attributes["title"]

      assert %{"type" => "string", "format" => "date-time", "nullable" => true} =
               attributes["due_at"]

      assert %{"type" => "string", "enum" => ["open", "done"], "nullable" => true} =
               attributes["status"]

      success =
        contract["paths"]["/api/notes/archive"]["post"]["responses"]["201"]["content"][
          "application/vnd.api+json"
        ]["schema"]["properties"]["success"]

      assert success == %{"type" => "boolean"}
    end
  end

  test "UtcDateTime stores microseconds and declares a date-time string" do
    assert Contracts.UtcDateTime.json_schema([]) == %OpenApiSpex.Schema{
             type: :string,
             format: :"date-time"
           }

    assert Contracts.UtcDateTime.json_write_schema([]) == %{
             "type" => "string",
             "format" => "date-time"
           }

    {:ok, constraints} = Ash.Type.init(Contracts.UtcDateTime, [])
    assert Ash.Type.storage_type(Contracts.UtcDateTime, constraints) == :utc_datetime_usec

    assert Ash.Type.cast_input(Contracts.UtcDateTime, "2026-11-01T10:00:00.123456Z", constraints) ==
             {:ok, ~U[2026-11-01 10:00:00.123456Z]}
  end
end
