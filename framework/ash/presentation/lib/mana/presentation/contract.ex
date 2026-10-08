defmodule Mana.Presentation.Contract do
  @moduledoc "Bounded compiler contract. Unsupported inputs fail explicitly, never become guessed controls."
  def build(resource, options \\ []) do
    forms = Spark.Dsl.Extension.get_entities(resource, [:forms])
    if forms == [], do: raise(ArgumentError, "No forms declared on #{inspect(resource)}")

    %{
      version: 1,
      client_validation: "presence_and_supported_type_constraints",
      server_validation: "authoritative",
      resource: inspect(resource),
      forms: Enum.map(forms, &form(resource, &1, options))
    }
  end

  defp form(resource, form, options) do
    name!(form.name)
    action = Ash.Resource.Info.action(resource, form.action)

    unless action && action.type in [:create, :update],
      do: raise(ArgumentError, "Form #{form.name} requires a create/update action")

    if form.inputs == [], do: raise(ArgumentError, "Form #{form.name} has no inputs")
    if form.create_identity do
      identity = Ash.Resource.Info.attribute(resource, form.create_identity)
      unless form.transport == :json_api && action.type == :create && !action.upsert? &&
               Ash.Resource.Info.primary_key(resource) == [form.create_identity] &&
               identity && identity.type == Ash.Type.UUID && identity.public? && identity.writable? &&
               form.create_identity in (action.accept || []) &&
               !Enum.any?(action.arguments, &(&1.name == form.create_identity)) &&
               !Enum.any?(form.inputs, &(&1.name == form.create_identity)),
        do: raise(ArgumentError, "create_identity requires an accepted public UUID primary key on a non-upsert JSON:API create, separate from form inputs")
    end
    names = Enum.map(form.inputs, & &1.name)
    keys = [form.submit_key | Enum.map(form.inputs, & &1.key)]

    if length(Enum.uniq(names)) != length(names) || length(Enum.uniq(keys)) != length(keys),
      do: raise(ArgumentError, "Duplicate form field or gesture key")

    if Enum.any?(keys, &(!is_binary(&1) || byte_size(&1) == 0 || byte_size(&1) > 128)),
      do: raise(ArgumentError, "Invalid form gesture key")

    inputs =
      Enum.map(form.inputs, fn input ->
        name!(input.name)
        argument = Enum.find(action.arguments, &(&1.name == input.name))

        if argument && !argument.public?,
          do: raise(ArgumentError, "#{input.name} is a private action argument")

        attribute = Ash.Resource.Info.attribute(resource, input.name)

        accepted =
          attribute && input.name in (action.accept || []) && attribute.writable? &&
            attribute.public?

        field = argument || if(accepted, do: attribute)

        unless field,
          do:
            raise(
              ArgumentError,
              "#{input.name} is not an accepted public input of #{form.action}"
            )

        %{
          name: Atom.to_string(input.name),
          label: input.label,
          key: input.key,
          invalid: input.invalid,
          required: !field.allow_nil?,
          sensitive: field.sensitive?
        }
        |> Map.merge(type_contract(field))
      end)

    %{
      name: Atom.to_string(form.name),
      action: Atom.to_string(form.action),
      submit: form.submit,
      submit_key: form.submit_key,
      failure: form.failure,
      inputs: inputs,
      binding:
        if(form.transport == :json_api,
          do: Mana.Presentation.Transport.build(resource, action, inputs, Keyword.put(options, :create_identity, form.create_identity))
        )
    }
  end

  defp type_contract(%{type: Ash.Type.String, constraints: constraints}) do
    count = Ash.Type.String.length_count(constraints)
    unless count in [:codepoints, :graphemes, :bytes],
      do: raise(ArgumentError, "Unsupported string length unit")
    %{type: "string", trim: Keyword.get(constraints, :trim?, true),
      allow_empty: Keyword.get(constraints, :allow_empty?, false),
      min: constraints[:min_length], max: constraints[:max_length], count: Atom.to_string(count)}
  end

  defp type_contract(%{type: Ash.Type.Integer, constraints: constraints}) do
    min = constraints[:min]
    max = constraints[:max]
    # Flutter web must represent every accepted value exactly, like native Dart.
    unless is_integer(min) && is_integer(max) && min <= max &&
             min >= -9_007_199_254_740_991 && max <= 9_007_199_254_740_991,
      do: raise(ArgumentError, "Integer inputs require explicit min/max within the exact web integer range")
    %{type: "integer", min: min, max: max}
  end

  defp type_contract(_),
    do: raise(ArgumentError, "Only string and bounded integer inputs are supported")

  defp name!(name) do
    unless Regex.match?(~r/^[a-z][a-z0-9]*(?:_[a-z][a-z0-9]*)*$/, Atom.to_string(name)),
      do: raise(ArgumentError, "Presentation identifiers must use lower snake_case")

    if Atom.to_string(name) in ~w(class enum extends final const var void return switch case default if else new this super null true false is as in with mixin import export library part required late static),
      do: raise(ArgumentError, "Reserved Dart identifier in presentation")
  end
end
