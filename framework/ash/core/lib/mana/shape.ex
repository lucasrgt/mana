defmodule Mana.Shape do
  @moduledoc """
  Names an embedded resource in the API: `use Mana.Shape` (or
  `use Mana.Shape, name: "PublicService"`) makes `Mana.Domain.OpenApi.put_shapes/2`
  publish one component for it, read and written alike.
  """
  defmacro __using__(opts) do
    quote do
      def __mana_shape__, do: unquote(opts[:name]) || __MODULE__ |> Module.split() |> List.last()
    end
  end
end
