defmodule Mana.Presentation.Transport do
  @moduledoc "Resolve an Ash action against the recorded OpenAPI of the generated Dart client."
  def build(resource, action, inputs, options) do
    spec = Keyword.get(options, :api_spec)
    package = Keyword.get(options, :api_package)

    unless is_map(spec) && is_binary(package) && Regex.match?(~r/^[a-z][a-z0-9_]*$/, package),
      do: fail("JSON:API forms require a recorded Dart client (--api-client)")

    domain = Ash.Resource.Info.domain(resource)
    method = if action.type == :create, do: :post, else: :patch

    routes =
      AshJsonApi.Resource.Info.routes(resource, domain)
      |> Enum.filter(&(&1.action == action.name && &1.method == method))

    route =
      case routes do
        [route] ->
          route

        _ ->
          fail(
            "Expected one JSON:API route for #{action.name}; ambiguous or absent routes need an explicit callback"
          )
      end

    if route.upsert? || route.relationship_arguments != [],
      do: fail("Upsert/relationship writes require an explicit callback")

    unless is_binary(route.name) && Regex.match?(~r/^[a-z][A-Za-z0-9]*$/, route.name),
      do: fail("JSON:API form routes need a lowerCamelCase operation name")

    operations =
      for {path, item} <- spec["paths"],
          {verb, op} <- item,
          is_map(op) && op["operationId"] == route.name,
          do: {path, verb, op}

    {path, verb, operation} =
      case operations do
        [value] -> value
        _ -> fail("Client contract must contain exactly one operation #{route.name}")
      end

    unless verb == Atom.to_string(method),
      do: fail("Client operation method differs from the Ash action")

    relative_path = Regex.replace(~r/:([a-z_][a-z0-9_]*)/, route.route, "{\\1}")

    unless String.ends_with?(
             String.trim_trailing(path, "/"),
             String.trim_trailing(relative_path, "/")
           ),
           do: fail("Client operation path differs from the Ash route")

    resource_type = AshJsonApi.Resource.Info.type(resource)

    unless is_binary(resource_type) && Regex.match?(~r/^[a-z][a-z0-9_]*$/, resource_type),
      do: fail("This transport requires a lower snake_case JSON:API resource type")

    # Paths and mandatory parameters must be satisfiable by this binding.
    expected_params = if method == :patch, do: ["id"], else: []
    path_params = Regex.scan(~r/\{([^}]+)\}/, path) |> Enum.map(&List.last/1)
    if path_params != expected_params, do: fail("Unsupported route parameters for #{route.name}")

    for param <- operation["parameters"] || [], param["required"] == true do
      unless param["in"] == "path" && param["name"] in expected_params,
        do: fail("Unsupported required parameter in #{route.name}")
    end

    request = get_in(operation, ["requestBody", "content", "application/vnd.api+json", "schema"])
    data = get_in(request || %{}, ["properties", "data"])
    attrs = get_in(data || %{}, ["properties", "attributes"])

    unless get_in(data || %{}, ["properties", "type", "enum"]) == [resource_type] &&
             is_map(attrs),
           do: fail("Expected the Ash JSON:API attribute request shape")

    if method == :patch && get_in(data, ["properties", "id", "type"]) != "string",
      do: fail("Update request requires a string id")

    identity = Keyword.get(options, :create_identity)
    identity = if identity, do: Atom.to_string(identity)
    if identity do
      field = get_in(attrs, ["properties", identity])
      unless field && field["type"] == "string" && field["format"] == "uuid",
        do: fail("Client contract is missing the UUID create_identity attribute")
    end
    names = Enum.map(inputs, & &1.name) ++ if(identity, do: [identity], else: [])
    missing = (attrs["required"] || []) -- names

    if missing != [],
      do: fail("Required client inputs missing from the form: #{Enum.join(missing, ", ")}")

    for input <- inputs do
      if method == :patch && !input.required,
        do:
          fail(
            "Nullable update inputs need an explicit callback until absence/null are represented separately"
          )

      field = get_in(attrs, ["properties", input.name])

      unless is_map(field) && field["type"] == input.type,
        do: fail("Client #{input.type} input missing or incompatible: #{input.name}")

      if !input.required && input.name in (attrs["required"] || []) && field["nullable"] != true,
        do: fail("Optional form field cannot satisfy required client input: #{input.name}")
    end

    success = if method == :post, do: "201", else: "200"

    ref =
      get_in(operation, [
        "responses",
        success,
        "content",
        "application/vnd.api+json",
        "schema",
        "properties",
        "data",
        "$ref"
      ])

    unless is_binary(ref) && String.starts_with?(ref, "#/components/schemas/"),
      do: fail("Expected a referenced resource receipt")

    schema = String.replace_prefix(ref, "#/components/schemas/", "")

    unless Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*$/, schema),
      do: fail("Unsupported response schema name")

    record = get_in(spec, ["components", "schemas", schema])

    unless get_in(record || %{}, ["properties", "id", "type"]) == "string" &&
             get_in(record || %{}, ["properties", "type", "type"]) == "string" &&
             schema == resource_type,
           do: fail("Client receipt does not identify the Ash resource")

    tag =
      case operation["tags"] do
        [tag] when is_binary(tag) -> tag
        _ -> fail("Expected a single generated-client API tag")
      end

    unless Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*$/, tag), do: fail("Unsupported API tag")

    %{
      package: package,
      operation: route.name,
      api: pascal(tag) <> "Api",
      request: pascal(route.name) <> "Request",
      record: pascal(schema),
      resource_type: resource_type,
      enum_value: camel(resource_type),
      update: method == :patch,
      create_identity: identity,
      status: String.to_integer(success)
    }
  end

  defp pascal(value), do: value |> Macro.underscore() |> Macro.camelize()

  defp camel(value) do
    <<first::utf8, rest::binary>> = pascal(value)
    String.downcase(<<first::utf8>>) <> rest
  end

  defp fail(message), do: raise(ArgumentError, message)
end
