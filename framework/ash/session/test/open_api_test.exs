defmodule Mana.Session.OpenApiTest do
  use ExUnit.Case, async: true

  alias Mana.Session.{ConfirmationOpenApi, OpenApi, RecoveryOpenApi}

  @resources %{
    "openapi" => "3.0.0",
    "paths" => %{"/api/notes" => %{"get" => %{"operationId" => "listNotes"}}},
    "components" => %{
      "schemas" => %{
        "Note" => %{"anyOf" => [%{"type" => "string"}, %{"type" => "null"}]}
      }
    }
  }

  defp operations(spec),
    do: for({path, methods} <- spec["paths"], {method, _} <- methods, do: {method, path})

  defp responses(spec, path, method \\ "post"),
    do: spec["paths"][path][method]["responses"] |> Map.keys() |> Enum.sort()

  test "the session contract joins the normalized resource contract" do
    spec = OpenApi.modify(@resources, nil, [])

    assert spec["components"]["schemas"]["Note"] == %{"type" => "string", "nullable" => true}

    assert Enum.sort(operations(spec)) == [
             {"delete", "/auth/session"},
             {"get", "/api/notes"},
             {"get", "/auth/session"},
             {"post", "/auth/sign-in"},
             {"post", "/auth/sign-up"}
           ]

    assert responses(spec, "/auth/sign-up") == ["201", "422", "429", "503"]
    assert responses(spec, "/auth/sign-in") == ["200", "401", "429", "503"]
    assert responses(spec, "/auth/session", "get") == ["200", "401"]
    assert responses(spec, "/auth/session", "delete") == ["204", "401", "503"]

    for path <- ["/auth/sign-up", "/auth/sign-in"] do
      assert spec["paths"][path]["post"]["security"] == []
      assert spec["paths"][path]["post"]["tags"] == ["Session"]
    end
  end

  test "credential schemas carry the transport's own limits" do
    schemas = OpenApi.modify(@resources, nil, [])["components"]["schemas"]

    assert schemas["SignInResult"]["required"] == ["accessToken", "userId", "email", "expiresAt"]
    refute "accessToken" in schemas["SessionView"]["required"]
    assert schemas["SignInInput"]["properties"]["email"]["maxLength"] == 254

    assert %{"maxLength" => 72, "writeOnly" => true, "format" => "password"} =
             schemas["SignInInput"]["properties"]["password"]

    sign_up = schemas["SignUpInput"]["properties"]
    assert sign_up["password"]["minLength"] == 12
    refute Map.has_key?(sign_up["passwordConfirmation"], "minLength")
  end

  test "recovery adds its two operations and reuses the sign-up password rules" do
    spec = RecoveryOpenApi.modify(@resources, nil, [])
    schemas = spec["components"]["schemas"]

    assert spec["paths"]["/auth/request-password-reset"]["post"]["operationId"] ==
             "requestPasswordReset"

    assert responses(spec, "/auth/request-password-reset") == ["202", "422", "429", "503"]
    assert responses(spec, "/auth/reset-password") == ["204", "422", "429", "503"]
    password = schemas["SignUpInput"]["properties"]["password"]
    assert schemas["ResetPasswordInput"]["properties"]["password"] == password
    assert schemas["ResetPasswordInput"]["properties"]["passwordConfirmation"] == password
    assert schemas["ResetPasswordInput"]["properties"]["token"]["maxLength"] == 8191
    assert Map.has_key?(spec["paths"], "/auth/sign-in")
  end

  test "confirmation turns sign-up into 202 and adds request and confirm operations" do
    spec = ConfirmationOpenApi.modify(@resources, nil, [])

    assert responses(spec, "/auth/sign-up") == ["202", "422", "429", "503"]

    assert spec["paths"]["/auth/request-confirmation"]["post"]["operationId"] ==
             "requestConfirmation"

    assert spec["paths"]["/auth/request-password-reset"]["post"]["operationId"] ==
             "requestPasswordReset"

    confirm = spec["paths"]["/auth/confirm-email"]["post"]
    assert confirm["operationId"] == "confirmEmail"
    assert confirm["security"] == []
    assert Map.keys(confirm["responses"]) |> Enum.sort() == ["204", "422", "429"]
    assert spec["paths"]["/auth/reset-password"]["post"]["operationId"] == "resetPassword"
  end

  test "every contract is plain JSON with unique operation ids" do
    for modifier <- [OpenApi, RecoveryOpenApi, ConfirmationOpenApi] do
      spec = modifier.modify(@resources, nil, [])
      assert spec == spec |> Jason.encode!() |> Jason.decode!()

      ids =
        for {_, methods} <- spec["paths"], {_, operation} <- methods, do: operation["operationId"]

      assert ids == Enum.uniq(ids), inspect(modifier)
    end
  end
end
