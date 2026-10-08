defmodule Contracts.UtcDateTime do
  @moduledoc "UTC microsecond storage with an explicit JSON date-time contract."
  use Ash.Type.NewType, subtype_of: :utc_datetime_usec
  use AshJsonApi.Type
  @impl true
  def json_schema(_constraints), do: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
  @impl true
  def json_write_schema(_constraints), do: %{"type" => "string", "format" => "date-time"}
end
