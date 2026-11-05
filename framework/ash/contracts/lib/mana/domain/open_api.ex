defmodule Mana.Domain.OpenApi do
  @moduledoc """
  Finishes the OpenAPI map AshJsonApi exports for a Mana app: `ErrorCode`, the
  enum of every declared error code, one component per `Mana.Enum` in place of
  its inline copies, one per `Mana.Shape`, each primitive's contract on its
  resource's schema and `x-mana-verb` on each operation.
  """
  @doc "Every Mana finishing step: error codes, enums, shapes and verbs."
  def finish(spec, domains),
    do:
      spec
      |> put_error_codes(domains)
      |> put_enums()
      |> put_shapes(domains)
      |> put_inline_shapes(domains)
      |> collapse_alternatives()
      |> put_contracts(domains)

  @doc "Alternatives that ended up identical (a read and an input of the same shape) become one."
  def collapse_alternatives(%{"anyOf" => options} = map) do
    case options
         |> Enum.map(&collapse_alternatives/1)
         |> Enum.uniq_by(&(&1 |> Jason.encode!() |> Jason.decode!())) do
      [only] -> map |> Map.delete("anyOf") |> Map.merge(only)
      many -> collapse_children(%{map | "anyOf" => many})
    end
  end

  def collapse_alternatives(map) when is_map(map), do: collapse_children(map)
  def collapse_alternatives(list) when is_list(list), do: Enum.map(list, &collapse_alternatives/1)
  def collapse_alternatives(value), do: value

  defp collapse_children(map),
    do:
      Map.new(map, fn {k, v} -> {k, if(k == "anyOf", do: v, else: collapse_alternatives(v))} end)

  def put_error_codes(spec, domains) do
    codes =
      domains
      |> Mana.Domain.Info.codes()
      |> Enum.concat(Mana.Error.platform_codes())
      |> Enum.uniq()
      |> Enum.sort()

    put_in(spec, ["components", "schemas", "ErrorCode"], %{"type" => "string", "enum" => codes})
  end

  def put_enums(spec) do
    {spec, enums} = hoist(spec, %{})

    Enum.reduce(enums, spec, fn {name, values}, spec ->
      put_in(spec, ["components", "schemas", name], %{"type" => "string", "enum" => values})
    end)
  end

  @doc """
  One component per `Mana.Shape` embedded resource, in place of the inline
  copy a read carries and the create/update inputs AshJsonApi derives, so a
  generated client has one class for it. The shape is the create input's.
  """
  def put_shapes(spec, domains) do
    uses =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          AshJsonApi.Resource in Spark.extensions(resource),
          type = AshJsonApi.Resource.Info.type(resource),
          attribute <- Ash.Resource.Info.public_attributes(resource),
          shape = shape_of(attribute.type),
          do: {to_string(type), to_string(attribute.name), shape}

    Enum.reduce(uses, spec, fn {type, attribute, name}, spec ->
      schemas = spec["components"]["schemas"]
      create = "#{type}_#{attribute}-input-create-type"
      update = "#{type}_#{attribute}-input-update-type"

      case schemas[name] || schemas[create] || inline(spec, type, attribute) do
        nil ->
          spec

        shape ->
          shape = guaranteed(shape, inline(spec, type, attribute))

          spec
          |> update_in(
            ["components", "schemas"],
            &(&1 |> Map.delete(create) |> Map.delete(update) |> Map.put(name, shape))
          )
          |> retarget(%{
            "#/components/schemas/#{create}" => name,
            "#/components/schemas/#{update}" => name
          })
          |> read_shape(type, attribute, name)
      end
    end)
  end

  @doc """
  The same component for a shape wherever a generic action returns or takes
  it: an inline object whose fields are exactly a shape's public attributes
  becomes a reference to it. A field set two shapes share is left inline.
  """
  def put_inline_shapes(spec, domains, shapes \\ nil) do
    by_fields =
      (shapes || app_shapes(domains))
      |> Enum.group_by(
        &(&1
          |> Ash.Resource.Info.public_attributes()
          |> MapSet.new(fn a -> to_string(a.name) end))
      )
      |> Enum.flat_map(fn
        {fields, [shape]} -> [{fields, shape.__mana_shape__()}]
        _ -> []
      end)
      |> Map.new()

    {components, rest} = Map.pop(spec, "components")
    {rest, found} = hoist_shapes(rest, by_fields, %{})

    {schemas, found} =
      Enum.reduce(components["schemas"], {%{}, found}, fn {name, schema}, {acc, found} ->
        {schema, found} =
          if Map.values(by_fields) |> Enum.member?(name),
            do: hoist_children(schema, by_fields, found),
            else: hoist_shapes(schema, by_fields, found)

        {Map.put(acc, name, schema), found}
      end)

    schemas =
      Enum.reduce(found, schemas, fn {name, schema}, acc -> Map.put_new(acc, name, schema) end)

    Map.put(rest, "components", Map.put(components, "schemas", schemas))
  end

  defp app_shapes(domains) do
    domains
    |> Enum.map(&Application.get_application/1)
    |> Enum.uniq()
    |> Enum.flat_map(&((&1 && Application.spec(&1, :modules)) || []))
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :__mana_shape__, 0)))
  end

  defp hoist_shapes(
         %{"type" => "object", "properties" => %{} = properties} = map,
         by_fields,
         found
       )
       when map_size(properties) > 0 do
    {map, found} = hoist_children(map, by_fields, found)

    case by_fields[MapSet.new(Map.keys(properties))] do
      nil ->
        {map, found}

      name ->
        {%{"$ref" => "#/components/schemas/#{name}"},
         Map.put_new(found, name, Map.delete(map, "nullable"))}
    end
  end

  defp hoist_shapes(%{"$ref" => _} = ref, _, found), do: {ref, found}

  defp hoist_shapes(map, by_fields, found) when is_map(map),
    do: hoist_children(map, by_fields, found)

  defp hoist_shapes(list, by_fields, found) when is_list(list),
    do: Enum.map_reduce(list, found, &hoist_shapes(&1, by_fields, &2))

  defp hoist_shapes(value, _, found), do: {value, found}

  defp hoist_children(map, by_fields, found) do
    Enum.reduce(map, {%{}, found}, fn {key, value}, {acc, found} ->
      {value, found} = hoist_shapes(value, by_fields, found)
      {Map.put(acc, key, value), found}
    end)
  end

  # One class reads and writes a shape: what every read returns is required,
  # so a field with a default is never nullable for the reader.
  defp guaranteed(shape, %{"required" => read}) when is_list(read) do
    shape
    |> Map.update("required", read, &Enum.uniq(&1 ++ read))
    |> Map.update("properties", %{}, fn properties ->
      Map.new(properties, fn {name, property} ->
        {name, if(name in read and is_map(property), do: present(property), else: property)}
      end)
    end)
  end

  defp guaranteed(shape, _), do: shape

  defp present(%{"anyOf" => options} = property) do
    case Enum.reject(options, &(&1 == %{"type" => "null"})) do
      [only] -> only
      many -> %{property | "anyOf" => many}
    end
  end

  defp present(property), do: Map.delete(property, "nullable")

  # A shape no action writes is still described by the read schema.
  defp inline(spec, type, attribute) do
    case get_in(spec, [
           "components",
           "schemas",
           type,
           "properties",
           "attributes",
           "properties",
           attribute
         ]) do
      %{"type" => "array", "items" => %{"type" => "object"} = items} -> items
      %{"type" => "object"} = object -> object
      _ -> nil
    end
  end

  defp shape_of({:array, type}), do: shape_of(type)

  # Loaded first: an embedded type nothing has touched yet would otherwise not look like a shape.
  defp shape_of(type) when is_atom(type),
    do:
      if(Code.ensure_loaded?(type) and function_exported?(type, :__mana_shape__, 0),
        do: type.__mana_shape__()
      )

  defp shape_of(_), do: nil

  defp retarget(%{"$ref" => ref} = map, targets) when is_map_key(targets, ref),
    do: %{map | "$ref" => "#/components/schemas/#{targets[ref]}"}

  defp retarget(map, targets) when is_map(map),
    do: Map.new(map, fn {k, v} -> {k, retarget(v, targets)} end)

  defp retarget(list, targets) when is_list(list), do: Enum.map(list, &retarget(&1, targets))
  defp retarget(value, _), do: value

  defp read_shape(spec, type, attribute, name) do
    path = ["components", "schemas", type, "properties", "attributes", "properties", attribute]
    ref = %{"$ref" => "#/components/schemas/#{name}"}

    case get_in(spec, path) do
      %{"type" => "array"} = list -> put_in(spec, path, Map.put(list, "items", ref))
      %{} -> put_in(spec, path, ref)
      nil -> spec
    end
  end

  # Siblings of a `$ref` are ignored in OpenAPI 3.0; a nullable use stays
  # nullable by not being required.
  defp hoist(%{"x-mana-enum" => name, "enum" => values}, enums),
    do: {%{"$ref" => "#/components/schemas/#{name}"}, Map.put(enums, name, values)}

  defp hoist(map, enums) when is_map(map) do
    Enum.reduce(map, {%{}, enums}, fn {key, value}, {acc, enums} ->
      {value, enums} = hoist(value, enums)
      {Map.put(acc, key, value), enums}
    end)
  end

  defp hoist(list, enums) when is_list(list), do: Enum.map_reduce(list, enums, &hoist/2)
  defp hoist(value, enums), do: {value, enums}

  @doc "Each resource's primitive contracts on its schema, and the primitives used under `info.x-mana-primitives`."
  def put_contracts(spec, domains) do
    spec = put_operations(spec, domains)

    placed =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          AshJsonApi.Resource in Spark.extensions(resource),
          type = to_string(AshJsonApi.Resource.Info.type(resource)),
          is_map(get_in(spec, ["components", "schemas", type])),
          primitive <- Mana.Primitive.of(resource),
          value = primitive.contract(resource),
          value not in [nil, [], %{}],
          do: {type, primitive, value}

    spec =
      Enum.reduce(placed, spec, fn {type, primitive, value}, spec ->
        put_in(
          spec,
          ["components", "schemas", type, primitive.__mana_primitive__().contract],
          value
        )
      end)

    case placed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        spec

      used ->
        manifest =
          for primitive <- Enum.sort_by(used, & &1.__mana_primitive__().contract) do
            meta = primitive.__mana_primitive__()

            %{
              "contract" => meta.contract,
              "catalog" => meta.catalog,
              "moments" => Enum.map(meta.moments, &to_string/1)
            }
          end

        Map.update(
          spec,
          "info",
          %{"x-mana-primitives" => manifest},
          &Map.put(&1, "x-mana-primitives", manifest)
        )
    end
  end

  @doc """
  Marks each JSON:API operation with the verbs it performs
  (`x-mana-verb: ["booking.cancel"]`), so a client knows from the route
  alone how a call retries and whether it may wait offline.
  """
  def put_operations(spec, domains) do
    marks =
      for domain <- domains,
          route <- AshJsonApi.Domain.Info.routes(domain),
          route.name,
          resource = route.resource,
          Mana.Verbs in Spark.extensions(resource),
          names =
            for(
              verb <- Mana.Verbs.declared(resource),
              Mana.Verbs.action(verb) == route.action,
              do: "#{Mana.Entity.type(resource)}.#{verb.name}"
            ),
          names != [],
          into: %{},
          do: {route.name, names}

    Map.update(spec, "paths", %{}, fn paths ->
      Map.new(paths, fn {path, operations} ->
        {path,
         Map.new(operations, fn
           {method, %{"operationId" => id} = operation} when is_map_key(marks, id) ->
             {method, Map.put(operation, "x-mana-verb", marks[id])}

           other ->
             other
         end)}
      end)
    end)
  end
end
