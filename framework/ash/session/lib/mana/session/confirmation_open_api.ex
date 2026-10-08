defmodule Mana.Session.ConfirmationOpenApi do
  @moduledoc "Explicit adoption changes signup to 202/pending; existing session contracts stay unchanged."
  def modify(spec, conn, opts) do
    spec = Mana.Session.RecoveryOpenApi.modify(spec, conn, opts)
    signup = spec["paths"]["/auth/sign-up"]["post"]["responses"]
      |> Map.delete("201")
      |> Map.put("202", %{"description" => "Account pending email confirmation; no session issued"})
    request = spec["paths"]["/auth/request-password-reset"]["post"]
      |> Map.put("operationId", "requestConfirmation")
    confirm = %{
      "operationId" => "confirmEmail", "tags" => ["Session"], "security" => [],
      "requestBody" => %{"required" => true, "content" => %{"application/json" => %{
        "schema" => %{"type" => "object", "required" => ["token"], "properties" => %{
          "token" => %{"type" => "string", "writeOnly" => true, "maxLength" => 8191}
        }}
      }}},
      "responses" => %{"204" => %{"description" => "Email confirmed; sign in explicitly"},
        "422" => %{"description" => "Invalid or consumed token"}, "429" => request["responses"]["429"]}
    }
    spec
    |> put_in(["paths", "/auth/sign-up", "post", "responses"], signup)
    |> put_in(["paths", "/auth/request-confirmation"], %{"post" => request})
    |> put_in(["paths", "/auth/confirm-email"], %{"post" => confirm})
  end
end
