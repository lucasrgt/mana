defmodule Moments.Manifest do
  @moduledoc "Exports the compiled DSL as a portable, credential-free view contract."
  alias Spark.Dsl.Extension, as: Dsl

  def build_many(modules, opts \\ []) do
    manifests = Enum.map(modules, &build(&1, Keyword.put(opts, :defer_lineage, true)))

    screens =
      Map.new(manifests, fn m ->
        [route] = m["properties"]["route"]["enum"]
        {route, Map.take(m, ["properties", "watch", "clientRoots"])}
      end)

    scenes = Enum.flat_map(manifests, &Map.to_list(&1["moments"]))

    if map_size(screens) != length(modules) or map_size(Map.new(scenes)) != length(scenes),
      do: raise(ArgumentError, "duplicate screen route or moment name")

    %{
      "version" => 2,
      "screens" => screens,
      "moments" => Map.new(scenes),
      "watch" => manifests |> Enum.flat_map(& &1["watch"]) |> Enum.uniq()
    }
    |> lineage()
  end

  def build(module, opts \\ []) do
    route = Dsl.get_opt(module, [:moments], :route)

    unless is_binary(route) and String.starts_with?(route, "/") and
             not String.starts_with?(route, "//"),
           do: raise(ArgumentError, "moment route must be local to the app")

    client_roots = Dsl.get_opt(module, [:moments], :client_roots, [])

    unless Enum.all?(
             client_roots,
             &Regex.match?(~r/^lib\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.dart$/, &1)
           ),
           do: raise(ArgumentError, "client_roots must name Dart libraries under lib/")

    entities = Dsl.get_entities(module, [:moments])
    fields = Enum.filter(entities, &is_struct(&1, Moments.Field))
    scenes = Enum.filter(entities, &is_struct(&1, Moments.Scene))
    if scenes == [], do: raise(ArgumentError, "declare at least one moment")
    if Enum.any?(fields, &(&1.name == :route)), do: raise(ArgumentError, "route is reserved")

    properties =
      Map.new(fields, fn field ->
        rule = rule(field)

        {to_string(field.name),
         if(field.restore == false, do: Map.put(rule, "restore", false), else: rule)}
      end)

    defaults = Map.new(fields, &{to_string(&1.name), &1.default})
    validate!(defaults, properties)

    moments =
      Map.new(scenes, fn scene ->
        name = scene.name |> to_string() |> String.replace("_", "-")

        unless Regex.match?(~r/^[a-z][a-z0-9-]*$/, name),
          do: raise(ArgumentError, "invalid moment name")

        state =
          Map.merge(
            defaults,
            Map.new(scene.defaults, fn {key, value} -> {to_string(key), value} end)
          )

        validate!(state, properties)

        if Enum.any?(scene.defaults, fn {key, _} ->
             properties[to_string(key)]["restore"] == false
           end),
           do: raise(ArgumentError, "cannot set defaults for observation fields")

        # Observations have a type but cannot be fabricated by a restore recipe.
        state = Map.reject(state, fn {key, _} -> properties[key]["restore"] == false end)

        {name,
         %{
           "description" => scene.description,
           "projection" => Map.put(state, "route", route),
           "checks" => checks(scene.checks, properties),
           "steps" => steps(scene.steps, scene.checks),
           "source" => source(scene, module, Keyword.get(opts, :source_root, File.cwd!()))
         }
         |> parent(scene.from)
         |> platforms(scene.platforms)
         |> backend(scene.backend, Dsl.get_opt(module, [:moments], :base))}
      end)

    if map_size(moments) != length(scenes),
      do: raise(ArgumentError, "duplicate normalized moment name")

    %{
      "version" => 1,
      "generator" => "Moments.Extension",
      "domain" => inspect(module),
      "properties" => Map.put(properties, "route", %{"enum" => [route]}),
      "clientRoots" => Enum.uniq(client_roots),
      "watch" => Enum.uniq(client_roots ++ Dsl.get_opt(module, [:moments], :watch, [])),
      "moments" => moments
    }
    |> then(fn manifest ->
      if Keyword.get(opts, :defer_lineage, false), do: manifest, else: lineage(manifest)
    end)
  end

  defp parent(scene, nil), do: scene
  defp parent(scene, from), do: Map.put(scene, "from", backend_name(from))

  defp platforms(scene, nil), do: scene
  defp platforms(_scene, []), do: raise(ArgumentError, "platforms cannot be empty")
  defp platforms(scene, list), do: Map.put(scene, "platforms", list |> Enum.uniq() |> Enum.map(&to_string/1))

  defp lineage(manifest) do
    moments = manifest["moments"]
    Enum.each(Map.keys(moments), &ancestors!(&1, moments, MapSet.new()))

    if Enum.any?(moments, fn {_name, scene} -> Map.has_key?(scene, "from") end) do
      manifest
      |> Map.put("version", 3)
      |> Map.put("protocol", %{"name" => "moments", "version" => "0.1", "profile" => "mana-ash-flutter"})
    else
      manifest
    end
  end

  defp ancestors!(nil, _moments, _seen), do: :ok
  defp ancestors!(name, moments, seen) do
    unless Map.has_key?(moments, name), do: raise(ArgumentError, "Unknown Moment parent: #{name}")
    if MapSet.member?(seen, name), do: raise(ArgumentError, "Moment parent cycle: #{name}")
    ancestors!(moments[name]["from"], moments, MapSet.put(seen, name))
  end

  defp backend(scene, nil, nil), do: scene
  defp backend(_scene, nil, _base), do: raise(ArgumentError, "base requires a backend recipe")

  defp backend(scene, recipe, base) do
    reference = %{"recipe" => backend_name(recipe)}
    reference = if base, do: Map.put(reference, "base", backend_name(base)), else: reference
    Map.put(scene, "backend", reference)
  end

  defp backend_name(recipe) do
    name = recipe |> Atom.to_string() |> String.replace("_", "-")

    unless Regex.match?(~r/^[a-z][a-z0-9-]*$/, name),
      do: raise(ArgumentError, "invalid backend recipe name")

    name
  end

  # Use the entity location captured by Spark instead of guessing from its name.
  # Export paths relative to the manifest, never the compiler/container checkout.
  defp source(scene, module, root) do
    case Spark.Dsl.Entity.anno(scene) do
      nil ->
        nil

      anno ->
        file = :erl_anno.file(anno)
        line = :erl_anno.line(anno)

        if file != :undefined and is_integer(line) and line > 0 do
          absolute = file |> to_string() |> Path.expand()

          %{
            "file" => Path.relative_to(absolute, Path.expand(root), force: true),
            "line" => line,
            "module" => inspect(module),
            "sha256" => :crypto.hash(:sha256, File.read!(absolute)) |> Base.encode16(case: :lower)
          }
        end
    end
  end

  defp checks(checks, properties) do
    if length(checks) > 64, do: raise(ArgumentError, "at most 64 checks per moment")
    names = Enum.map(checks, & &1.name)
    if length(names) != length(Enum.uniq(names)), do: raise(ArgumentError, "duplicate check name")

    Enum.map(checks, fn check ->
      field = if check.field, do: Atom.to_string(check.field)
      match = if check.match, do: Atom.to_string(check.match)

      if check.kind == :backend_equals and (is_nil(field) or is_nil(match)),
        do: raise(ArgumentError, "backend check needs field and matching UI identity")

      if match && !Map.has_key?(properties, match),
        do: raise(ArgumentError, "unknown check identity")

      if (check.kind in [:restored, :ui_equals] and field) && !Map.has_key?(properties, field),
        do: raise(ArgumentError, "unknown UI check field")

      if check.kind == :ui_equals and is_nil(field),
        do: raise(ArgumentError, "UI check needs a field")

      if (check.kind == :restored and field) && properties[field]["restore"] == false,
        do: raise(ArgumentError, "observations need ui_equals, not restored")

      if field &&
           !(is_boolean(check.equals) or is_number(check.equals) or is_binary(check.equals)),
         do: raise(ArgumentError, "check equals must be a scalar")

      %{"name" => to_string(check.name), "kind" => to_string(check.kind)}
      |> then(fn value ->
        if check.scope == :step, do: Map.put(value, "scope", "step"), else: value
      end)
      |> then(fn value ->
        if field, do: Map.merge(value, %{"field" => field, "equals" => check.equals}), else: value
      end)
      |> then(fn value -> if match, do: Map.put(value, "match", match), else: value end)
    end)
  end

  defp steps(steps, checks) do
    names = Enum.map(steps, & &1.name)

    if length(steps) > 32 or length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "journeys require at most 32 uniquely named steps")

    for check <- checks, check.scope == :step do
      unless check.kind in [:ui_equals, :backend_equals] and
               Enum.any?(steps, &(check.name in &1.until)),
             do: raise(ArgumentError, "step checks must be observed by a declared step")
    end

    Enum.map(steps, fn step ->
      gestures =
        [tap: step.tap, fill: step.fill, reveal: step.reveal, back: step.back, swipe: step.swipe, long_press: step.long_press, submit: step.submit]
        |> Enum.reject(fn {_, value} -> value in [nil, false] end)

      {kind, target} =
        case gestures do
          [{:fill, key}] when is_binary(step.from) -> {"fill", key}
          [{:back, true}] when is_nil(step.from) -> {"back", "system.back"}
          [{:reveal, key}] when is_nil(step.from) -> {"reveal", key}
          [{kind, key}] when kind in [:tap, :swipe, :long_press, :submit] and is_binary(key) -> {to_string(kind), key}
          _ -> raise(ArgumentError, "step requires exactly one of tap, fill/from, reveal, back, swipe, long_press or submit")
        end

      unless (kind == "swipe") == not is_nil(step.direction),
        do: raise(ArgumentError, "swipe requires a direction, and only swipe takes one")

      valid = fn value ->
        is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9_.:-]{1,160}$/, value)
      end

      unless valid.(target) and (is_nil(step.from) or valid.(step.from)),
        do: raise(ArgumentError, "step requires bounded widget keys and input references")

      unless length(step.until) in 0..32 and
               Enum.all?(step.until, fn name ->
                 Enum.any?(
                   checks,
                   &(&1.name == name and &1.kind in [:ui_equals, :backend_equals])
                 )
               end),
             do:
               raise(
                 ArgumentError,
                 "until references must name observed UI or backend criteria"
               )

      %{
        "name" => to_string(step.name),
        "kind" => kind,
        "target" => target,
        "until" => Enum.map(step.until, &to_string/1)
      }
      |> then(fn value ->
        if step.from, do: Map.put(value, "inputRef", step.from), else: value
      end)
      |> then(fn value ->
        if step.direction, do: Map.put(value, "direction", to_string(step.direction)), else: value
      end)
    end)
  end

  defp rule(%{values: nil, min: nil, max: nil, max_entries: nil, max_length: n})
       when is_integer(n),
       do: %{"type" => "string", "maxLength" => n}

  defp rule(%{values: nil, min: min, max: max, max_entries: n, max_length: k})
       when is_integer(n) and is_integer(k) and is_number(min) and is_number(max) and min <= max,
       do: %{
         "type" => "object",
         "maxProperties" => n,
         "keyMaxLength" => k,
         "values" => %{"type" => "integer", "min" => min, "max" => max}
       }

  defp rule(%{values: values, min: nil, max: nil, max_entries: nil, max_length: nil})
       when is_list(values) and values != [],
       do: %{"enum" => values}

  defp rule(%{values: nil, min: min, max: max, max_entries: nil, max_length: nil})
       when is_number(min) and is_number(max) and min <= max,
       do: %{"type" => "number", "min" => min, "max" => max}

  defp rule(field),
    do: raise(ArgumentError, "#{field.name}: declare values or a bounded numeric range")

  defp utf16_length(value),
    do: div(byte_size(:unicode.characters_to_binary(value, :utf8, {:utf16, :little})), 2)

  defp validate!(state, properties) do
    unless Enum.sort(Map.keys(state)) == Enum.sort(Map.keys(properties)),
      do: raise(ArgumentError, "moment defaults contain undeclared fields")

    Enum.each(state, fn {key, value} ->
      valid =
        case properties[key] do
          %{"enum" => values} ->
            value in values

          %{"type" => "string", "maxLength" => n} ->
            is_binary(value) and utf16_length(value) <= n

          %{"type" => "object", "maxProperties" => n, "keyMaxLength" => k, "values" => bounds} ->
            is_map(value) and map_size(value) <= n and
              Enum.all?(value, fn {key, rating} ->
                is_binary(key) and utf16_length(key) <= k and is_integer(rating) and
                  rating >= bounds["min"] and rating <= bounds["max"]
              end)

          %{"min" => min, "max" => max} ->
            is_number(value) and value >= min and value <= max
        end

      unless valid, do: raise(ArgumentError, "#{key}: invalid moment default #{inspect(value)}")
    end)
  end
end
