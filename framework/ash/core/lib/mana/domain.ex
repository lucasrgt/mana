defmodule Mana.Domain.ErrorCode do
  @moduledoc false
  defstruct [:name, :code, :status, :message, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Domain do
  @moduledoc """
  Domain-level product contracts. `errors` is the catalog of refusals this domain
  may return, each with a stable code and a 4xx status:

      errors do
        error :email_taken, "account.email_taken", status: 409,
          message: "an account with this email already exists"
      end

  The domain gains `error(name, opts \\\\ [])`, returning a `Mana.Error` to return or
  raise from actions. Codes are exported in the OpenAPI contract (see
  `Mana.Domain.OpenApi`) so clients can map them exhaustively.
  """
  @error %Spark.Dsl.Entity{
    name: :error,
    target: Mana.Domain.ErrorCode,
    args: [:name, :code],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      code: [type: :string, required: true],
      status: [type: {:in, Enum.to_list(400..499)}, required: true],
      message: [type: :string, required: true]
    ]
  }

  @errors %Spark.Dsl.Section{name: :errors, entities: [@error]}

  # Checks run in a transformer, not a verifier: Spark reports verifier failures as
  # warnings, and these must fail compilation.
  use Spark.Dsl.Extension, sections: [@errors], transformers: [Mana.Domain.DefineErrors]
end

defmodule Mana.Domain.Info do
  @moduledoc false
  use Spark.InfoGenerator, extension: Mana.Domain, sections: [:errors]

  def codes(domains), do: domains |> Enum.flat_map(&errors/1) |> Enum.map(& &1.code)
end

defmodule Mana.Domain.DefineErrors do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Mana.Domain.Info
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  def transform(dsl) do
    errors = Transformer.get_entities(dsl, [:errors])

    cond do
      bad =
          Enum.find(
            errors,
            &(not Regex.match?(~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$/, &1.code))
          ) ->
        error(dsl, "error code #{inspect(bad.code)} must look like `area.reason`")

      dup = duplicate(errors) ->
        error(dsl, "error code #{inspect(dup)} is declared twice")

      true ->
        {:ok,
         Transformer.eval(
           dsl,
           [],
           quote do
             def error(name, opts \\ []) do
               case Enum.find(Info.errors(__MODULE__), &(&1.name == name)) do
                 nil ->
                   raise ArgumentError,
                         "#{inspect(__MODULE__)} declares no error #{inspect(name)}"

                 e ->
                   Mana.Error.new(e.code, e.message, Keyword.merge([status: e.status], opts))
               end
             end
           end
         )}
    end
  end

  defp duplicate(errors) do
    errors
    |> Enum.frequencies_by(& &1.code)
    |> Enum.find_value(fn {code, n} -> if n > 1, do: code end)
  end

  defp error(dsl, message),
    do:
      {:error,
       DslError.exception(
         module: Transformer.get_persisted(dsl, :module),
         path: [:errors],
         message: message
       )}
end
