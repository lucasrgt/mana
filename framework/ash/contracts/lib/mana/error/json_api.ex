# How a Mana.Error reaches a JSON:API client: its code, status, field and meta.
defimpl AshJsonApi.ToJsonApiError, for: Mana.Error do
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
