defmodule Mana.Error do
  @moduledoc """
  A refusal with a stable product code (`account.email_taken`). Clients map codes to
  copy, so codes are contract; the message is diagnostic and never shown for 5xx.
  Declare codes in a domain `errors` section and raise them with `Domain.error/1`.
  """
  use Splode.Error, fields: [:code, :message, :status, :field, meta: %{}], class: :invalid

  def message(%{message: message}), do: message

  @doc "Codes produced by Mana itself rather than declared by a domain."
  def platform_codes, do: ["platform.rate_limited", "platform.unavailable", "verb.unavailable" | Mana.Uploads.codes()]

  def new(code, message, opts \\ []) do
    exception(
      code: code,
      message: message,
      status: Keyword.get(opts, :status, 422),
      field: Keyword.get(opts, :field),
      meta: Map.new(Keyword.get(opts, :meta, %{}))
    )
  end

  if Code.ensure_loaded?(AshJsonApi.ToJsonApiError) do
    defimpl AshJsonApi.ToJsonApiError do
      def to_json_api_error(error) do
        %AshJsonApi.Error{
          id: Ash.UUID.generate(),
          status_code: error.status,
          code: error.code,
          title: error.code,
          detail: error.message,
          source_parameter: error.field && to_string(error.field),
          meta: error.meta
        }
      end
    end
  end
end
