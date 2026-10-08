defmodule Mana.Session.RecoveryOpenApi do
  @moduledoc "Opt-in recovery contract; existing session-only apps keep their contract."
  def modify(spec, conn, opts) do
    spec = Mana.Session.OpenApi.modify(spec, conn, opts)
    password = spec["components"]["schemas"]["SignUpInput"]["properties"]["password"]

    schemas =
      Map.merge(spec["components"]["schemas"], %{
        "RecoveryInput" => %{
          "type" => "object",
          "required" => ["email"],
          "properties" => %{
            "email" => %{"type" => "string", "maxLength" => 254}
          }
        },
        "ResetPasswordInput" => %{
          "type" => "object",
          "required" => ["token", "password", "passwordConfirmation"],
          "properties" => %{
            "token" => %{"type" => "string", "writeOnly" => true, "maxLength" => 8191},
            "password" => password,
            "passwordConfirmation" => password
          }
        }
      })

    common = %{
      "422" => %{"description" => "Invalid request or unusable token"},
      "429" => %{
        "description" => "Too many attempts",
        "headers" => %{
          "Retry-After" => %{"schema" => %{"type" => "integer", "minimum" => 1}}
        }
      },
      "503" => %{"description" => "Recovery unavailable"}
    }

    paths =
      Map.merge(spec["paths"], %{
        "/auth/request-password-reset" =>
          operation(
            "requestPasswordReset",
            "RecoveryInput",
            Map.put(common, "202", %{
              "description" => "Request queued regardless of account existence"
            })
          ),
        "/auth/reset-password" =>
          operation(
            "resetPassword",
            "ResetPasswordInput",
            Map.put(common, "204", %{
              "description" => "Password changed; sign in again. Previous sessions revoked."
            })
          )
      })

    spec |> put_in(["components", "schemas"], schemas) |> Map.put("paths", paths)
  end

  defp operation(id, input, responses),
    do: %{
      "post" => %{
        "operationId" => id,
        "tags" => ["Session"],
        "security" => [],
        "requestBody" => %{
          "required" => true,
          "content" => %{
            "application/json" => %{
              "schema" => %{"$ref" => "#/components/schemas/#{input}"}
            }
          }
        },
        "responses" => responses
      }
    }
end
