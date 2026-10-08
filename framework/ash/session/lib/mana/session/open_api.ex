defmodule Mana.Session.OpenApi do
  @moduledoc "Portable HTTP session contract alongside generated Ash JSON:API resources."
  def modify(spec, conn, opts) do
    spec = Contracts.OpenApi.modify(spec, conn, opts)

    view = %{
      "type" => "object",
      "required" => ["userId", "email", "expiresAt"],
      "properties" => %{
        "userId" => %{"type" => "string", "format" => "uuid"},
        "email" => %{"type" => "string"},
        "expiresAt" => %{"type" => "string", "format" => "date-time"}
      }
    }

    result =
      view
      |> Map.put("required", ["accessToken" | view["required"]])
      |> put_in(["properties", "accessToken"], %{"type" => "string"})

    input = %{
      "type" => "object",
      "required" => ["email", "password"],
      "properties" => %{
        "email" => %{"type" => "string", "maxLength" => 254},
        "password" => %{
          "type" => "string",
          "format" => "password",
          "maxLength" => 72,
          "writeOnly" => true
        }
      }
    }

    schemas =
      Map.merge(spec["components"]["schemas"], %{
        "SessionView" => view,
        "SignInResult" => result,
        "SignInInput" => input,
        "SignUpInput" => %{
          "type" => "object",
          "required" => ["email", "password", "passwordConfirmation"],
          "properties" => %{
            "email" => input["properties"]["email"],
            "password" =>
              Map.merge(input["properties"]["password"], %{
                "minLength" => 12,
                "description" =>
                  "At least 12 Unicode codepoints, at most 72 UTF-8 bytes. Whitespace is preserved."
              }),
            "passwordConfirmation" => input["properties"]["password"]
          }
        }
      })

    paths =
      Map.merge(spec["paths"], %{
        "/auth/sign-up" => %{
          "post" => %{
            "operationId" => "signUp",
            "tags" => ["Session"],
            "security" => [],
            "requestBody" => %{"required" => true, "content" => content("SignUpInput")},
            "responses" => %{
              "201" => response("SignInResult"),
              "422" => %{
                "description" => "Registration rejected; invalid input or unavailable identity"
              },
              "429" => %{
                "description" => "Too many credential attempts",
                "headers" => %{
                  "Retry-After" => %{"schema" => %{"type" => "integer", "minimum" => 1}}
                }
              },
              "503" => %{"description" => "Registration unavailable"}
            }
          }
        },
        "/auth/sign-in" => %{
          "post" => %{
            "operationId" => "signIn",
            "tags" => ["Session"],
            "security" => [],
            "requestBody" => %{"required" => true, "content" => content("SignInInput")},
            "responses" => %{
              "200" => response("SignInResult"),
              "401" => %{"description" => "Invalid credentials"},
              "429" => %{
                "description" => "Too many sign-in attempts",
                "headers" => %{
                  "Retry-After" => %{
                    "schema" => %{"type" => "integer", "minimum" => 1},
                    "description" => "Seconds before retry"
                  }
                }
              },
              "503" => %{"description" => "Sign-in unavailable"}
            }
          }
        },
        "/auth/session" => %{
          "get" => %{
            "operationId" => "getSession",
            "tags" => ["Session"],
            "responses" => %{
              "200" => response("SessionView"),
              "401" => %{"description" => "Unauthenticated"}
            }
          },
          "delete" => %{
            "operationId" => "signOut",
            "tags" => ["Session"],
            "responses" => %{
              "204" => %{"description" => "Token revoked"},
              "401" => %{"description" => "Unauthenticated"},
              "503" => %{"description" => "Revocation unavailable"}
            }
          }
        }
      })

    spec |> put_in(["components", "schemas"], schemas) |> Map.put("paths", paths)
  end

  defp content(schema),
    do: %{"application/json" => %{"schema" => %{"$ref" => "#/components/schemas/#{schema}"}}}

  defp response(schema),
    do: %{"description" => "Authenticated session", "content" => content(schema)}
end
