defmodule Mana.Enum do
  @moduledoc """
  A closed set of values the contract names once.

      defmodule MyApp.Trips.Vehicle do
        use Mana.Enum, values: [:car, :motorbike, :bicycle]
      end

  It is an `Ash.Type.Enum`; in the OpenAPI document every field, argument and
  result that uses it points at one `Vehicle` component (see
  `Mana.Domain.OpenApi.put_enums/1`), so a generated client has one enum per
  concept instead of one per field. AshJsonApi reads `json_schema/1` for the
  document and `json_write_schema/1`, a plain JSON Schema map, to validate
  request bodies.
  """
  defmacro __using__(opts) do
    quote do
      use Ash.Type.Enum, values: unquote(opts[:values])

      def json_schema(_constraints) do
        struct(OpenApiSpex.Schema,
          type: :string,
          enum: Enum.map(values(), &to_string/1),
          extensions: %{"x-mana-enum" => unquote(opts[:name]) || Mana.Enum.component(__MODULE__)}
        )
      end

      def json_write_schema(_constraints) do
        %{
          "type" => "string",
          "enum" => Enum.map(values(), &to_string/1),
          "x-mana-enum" => unquote(opts[:name]) || Mana.Enum.component(__MODULE__)
        }
      end
    end
  end

  @doc false
  def component(module), do: module |> Module.split() |> List.last()
end
