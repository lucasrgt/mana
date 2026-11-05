defmodule Contracts.ManaOpenApiTest do
  # mana_core's fixture resources (test/fixtures in mana_core) exported through JSON:API.
  use ExUnit.Case, async: true

  alias Mana.Domain.OpenApi

  test "route patterns match parameters but not prefixes" do
    routes = [{"POST", ["api", "account", "register"]}, {"DELETE", ["api", "sessions", ":id"]}]

    assert Mana.Router.match?(
             %{method: "POST", path_info: ["api", "account", "register"]},
             routes
           )

    assert Mana.Router.match?(%{method: "DELETE", path_info: ["api", "sessions", "abc"]}, routes)
    refute Mana.Router.match?(%{method: "GET", path_info: ["api", "account", "register"]}, routes)
    refute Mana.Router.match?(%{method: "DELETE", path_info: ["api", "sessions"]}, routes)
  end

  test "a Mana.Shape is one component for its read copy and its create and update inputs" do
    create = %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string"}},
      "required" => ["label"]
    }

    ref = &%{"$ref" => "#/components/schemas/#{&1}"}

    spec = %{
      "components" => %{
        "schemas" => %{
          "gizmo_parts-input-create-type" => create,
          "gizmo_parts-input-update-type" => %{"type" => "object"},
          "gizmo" => %{
            "properties" => %{
              "attributes" => %{
                "properties" => %{"parts" => %{"type" => "array", "items" => create}}
              }
            }
          }
        }
      },
      "paths" => %{
        "/gizmos" => %{
          "post" => ref.("gizmo_parts-input-create-type"),
          "patch" => ref.("gizmo_parts-input-update-type")
        }
      }
    }

    shaped = OpenApi.put_shapes(spec, [ManaCoreTest.Domain])
    schemas = shaped["components"]["schemas"]
    assert schemas["Part"] == create

    refute Map.has_key?(schemas, "gizmo_parts-input-create-type") or
             Map.has_key?(schemas, "gizmo_parts-input-update-type")

    assert schemas["gizmo"]["properties"]["attributes"]["properties"]["parts"]["items"] ==
             ref.("Part")

    assert shaped["paths"]["/gizmos"] == %{"post" => ref.("Part"), "patch" => ref.("Part")}
  end

  test "a Mana.Enum becomes one named component wherever it appears" do
    assert %{enum: ["red", "blue"], extensions: %{"x-mana-enum" => "Color"}} =
             ManaCoreTest.Color.json_schema([])

    inline = ManaCoreTest.Color.json_write_schema([])

    spec = %{
      "components" => %{"schemas" => %{}},
      "paths" => %{"/a" => %{"get" => %{"schema" => %{"items" => inline}, "other" => inline}}}
    }

    hoisted = OpenApi.put_enums(spec)
    assert hoisted["paths"]["/a"]["get"]["other"] == %{"$ref" => "#/components/schemas/Color"}

    assert hoisted["components"]["schemas"]["Color"] == %{
             "type" => "string",
             "enum" => ["red", "blue"]
           }
  end

  test "what every read returns stays required and non-null in a shape an input made optional" do
    create = %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string", "nullable" => true}},
      "required" => []
    }

    read = %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string"}},
      "required" => ["label"]
    }

    spec = %{
      "components" => %{
        "schemas" => %{
          "gizmo_parts-input-create-type" => create,
          "gizmo" => %{
            "properties" => %{
              "attributes" => %{
                "properties" => %{"parts" => %{"type" => "array", "items" => read}}
              }
            }
          }
        }
      },
      "paths" => %{}
    }

    part =
      OpenApi.put_shapes(spec, [ManaCoreTest.Domain])["components"]["schemas"]["Part"]

    assert part["required"] == ["label"]
    assert part["properties"]["label"] == %{"type" => "string"}
  end

  test "alternatives that ended up identical collapse into one" do
    list = %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Part"}}

    assert OpenApi.collapse_alternatives(%{"x" => %{"anyOf" => [list, list]}}) == %{
             "x" => list
           }

    two = %{"anyOf" => [list, %{"type" => "string"}]}
    assert OpenApi.collapse_alternatives(two) == two
  end

  test "an inline object with exactly a shape's fields becomes that shape's component" do
    part = %{"type" => "object", "properties" => %{"label" => %{"type" => "string"}}}

    wider = %{
      "type" => "object",
      "properties" => %{"label" => %{"type" => "string"}, "extra" => %{"type" => "integer"}}
    }

    ref = %{"$ref" => "#/components/schemas/Part"}

    spec = %{
      "components" => %{"schemas" => %{"Part" => part}},
      "paths" => %{
        "/a" => %{
          "get" => %{"schema" => %{"type" => "array", "items" => Map.put(part, "nullable", true)}}
        },
        "/b" => %{"post" => %{"schema" => wider}}
      }
    }

    shaped =
      OpenApi.put_inline_shapes(spec, [ManaCoreTest.Domain], [ManaCoreTest.Part])

    assert shaped["paths"]["/a"]["get"]["schema"]["items"] == ref
    assert shaped["paths"]["/b"]["post"]["schema"] == wider
    assert shaped["components"]["schemas"]["Part"] == part
  end

  test "primitives place their contracts on the schema and list themselves in info" do
    spec = %{
      "info" => %{"title" => "t"},
      "components" => %{"schemas" => %{"listing" => %{"type" => "object"}}}
    }

    placed = OpenApi.put_contracts(spec, [ManaCoreTest.Domain])

    assert [%{"attribute" => "cover_id"}, _] =
             placed["components"]["schemas"]["listing"]["x-mana-attachments"]

    assert placed["info"]["x-mana-primitives"] == [
             %{
               "contract" => "x-mana-attachments",
               "catalog" => "uploads",
               "moments" => ["fake", "observe"]
             }
           ]
  end
end
