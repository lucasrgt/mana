defmodule Moments.Manifest do
  @moduledoc "Exports the compiled DSL as a portable, credential-free view contract."
  alias Mana.Entity
  alias Mana.Verbs
  alias Spark.Dsl.Extension, as: Dsl

  # mana_core is optional: verb references check for it at runtime.
  @compile {:no_warn_undefined, [Mana.Entity, Mana.Verbs]}

  def build_many(modules, opts \\ []) do
    opts = opts |> Keyword.put(:defer_lineage, true) |> Keyword.put_new(:domains, modules)
    manifests = Enum.map(modules, &build(&1, opts))

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
    route = route!(Dsl.get_opt(module, [:moments], :route))
    client_roots = client_roots!(Dsl.get_opt(module, [:moments], :client_roots, []))
    {fields, scenes} = entities!(module)
    properties = Map.new(fields, &property/1)
    defaults = Map.new(fields, &{to_string(&1.name), &1.default})
    validate!(defaults, properties)

    context = %{
      module: module,
      opts: opts,
      route: route,
      defaults: defaults,
      properties: properties,
      verb: &verb!(&1, Keyword.get(opts, :domains, [module]), module)
    }

    moments = Map.new(scenes, &moment(&1, context))

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

  defp route!(route) do
    unless is_binary(route) and String.starts_with?(route, "/") and
             not String.starts_with?(route, "//"),
           do: raise(ArgumentError, "moment route must be local to the app")

    route
  end

  defp client_roots!(client_roots) do
    unless Enum.all?(
             client_roots,
             &Regex.match?(~r/^lib\/(?:[A-Za-z0-9_-]+\/)*[A-Za-z0-9_-]+\.dart$/, &1)
           ),
           do: raise(ArgumentError, "client_roots must name Dart libraries under lib/")

    client_roots
  end

  defp entities!(module) do
    entities = Dsl.get_entities(module, [:moments])
    fields = Enum.filter(entities, &is_struct(&1, Moments.Field))
    scenes = Enum.filter(entities, &is_struct(&1, Moments.Scene))
    if scenes == [], do: raise(ArgumentError, "declare at least one moment")
    if Enum.any?(fields, &(&1.name == :route)), do: raise(ArgumentError, "route is reserved")
    {fields, scenes}
  end

  defp property(field), do: {to_string(field.name), restore(rule(field), field.restore)}

  defp restore(rule, false), do: Map.put(rule, "restore", false)
  defp restore(rule, _restore), do: rule

  defp moment(scene, %{module: module, opts: opts, route: route} = context) do
    %{defaults: defaults, properties: properties, verb: verb} = context
    name = scene.name |> to_string() |> dashed!("invalid moment name")

    state =
      Map.merge(
        defaults,
        Map.new(scene.defaults, fn {key, value} -> {to_string(key), value} end)
      )

    validate!(state, properties)

    if Enum.any?(scene.defaults, fn {key, _} -> observation?(properties, key) end),
      do: raise(ArgumentError, "cannot set defaults for observation fields")

    # Observations have a type but cannot be fabricated by a restore recipe.
    state = Map.reject(state, fn {key, _} -> observation?(properties, key) end)

    {name,
     %{
       "description" => scene.description,
       "projection" => Map.put(state, "route", route),
       "checks" => checks(scene.checks, properties, verb),
       "steps" => steps(scene.steps, scene.checks, verb),
       "source" => source(scene, module, Keyword.get(opts, :source_root, File.cwd!()))
     }
     |> parent(scene.from)
     |> platforms(scene.platforms)
     |> backend(scene.backend, Dsl.get_opt(module, [:moments], :base))}
  end

  defp observation?(properties, key), do: properties[to_string(key)]["restore"] == false

  defp parent(scene, nil), do: scene
  defp parent(scene, from), do: Map.put(scene, "from", backend_name(from))

  defp platforms(scene, nil), do: scene
  defp platforms(_scene, []), do: raise(ArgumentError, "platforms cannot be empty")

  defp platforms(scene, list),
    do: Map.put(scene, "platforms", list |> Enum.uniq() |> Enum.map(&to_string/1))

  defp lineage(manifest) do
    moments = manifest["moments"]
    Enum.each(Map.keys(moments), &ancestors!(&1, moments, MapSet.new()))

    if Enum.any?(moments, fn {_name, scene} -> Map.has_key?(scene, "from") end) do
      manifest
      |> Map.put("version", 3)
      |> Map.put("protocol", %{
        "name" => "moments",
        "version" => "0.1",
        "profile" => "mana-ash-flutter"
      })
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

  defp backend_name(recipe),
    do: recipe |> Atom.to_string() |> dashed!("invalid backend recipe name")

  defp dashed!(name, message) do
    name = String.replace(name, "_", "-")
    unless Regex.match?(~r/^[a-z][a-z0-9-]*$/, name), do: raise(ArgumentError, message)
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

  # A verb is named `type.verb`, the way records list what they offer and
  # VerbGate keys its control; only a verb the resource declares is accepted.
  defp verb!({resource, name}, domains, module) when is_atom(resource) and is_atom(name) do
    unless Code.ensure_loaded?(Mana.Verbs) and Code.ensure_loaded?(Mana.Entity),
      do: raise(ArgumentError, "verb steps and checks need Mana.Verbs (mana_core)")

    resource = verb_resource!(resource, domains, module)

    unless Mana.Verbs in Spark.extensions(resource) and
             Enum.any?(Verbs.declared(resource), &(&1.name == name)),
           do: raise(ArgumentError, "#{inspect(resource)} declares no verb #{inspect(name)}")

    "#{Entity.type(resource)}.#{name}"
  end

  defp verb!(_reference, _domains, _module),
    do: raise(ArgumentError, "verb takes {Resource or :type, :verb_name}")

  defp verb_resource!(resource, domains, module) do
    if Code.ensure_loaded?(resource) and Ash.Resource.Info.resource?(resource) do
      resource
    else
      app = Application.get_application(module)
      domains = Enum.uniq(domains ++ ((app && Application.get_env(app, :ash_domains, [])) || []))
      type = to_string(resource)

      matches =
        for domain <- domains,
            Code.ensure_loaded?(domain),
            Spark.Dsl.is?(domain, Ash.Domain),
            candidate <- Ash.Domain.Info.resources(domain),
            Entity.type(candidate) == type,
            uniq: true,
            do: candidate

      case matches do
        [found] ->
          found

        [] ->
          raise(ArgumentError, "no resource of type #{inspect(resource)} in #{inspect(domains)}")

        _ ->
          raise(
            ArgumentError,
            "several resources have type #{inspect(resource)}; name the module"
          )
      end
    end
  end

  @check_rules [
    backend_identity: "backend check needs field and matching UI identity",
    known_identity: "unknown check identity",
    known_field: "unknown UI check field",
    ui_field: "UI check needs a field",
    restorable_field: "observations need ui_equals, not restored",
    scalar_equals: "check equals must be a scalar",
    verb_only: "offered and not_offered checks take a verb, and only a verb"
  ]

  defp checks(checks, properties, verb) do
    if length(checks) > 64, do: raise(ArgumentError, "at most 64 checks per moment")
    names = Enum.map(checks, & &1.name)
    if length(names) != length(Enum.uniq(names)), do: raise(ArgumentError, "duplicate check name")
    Enum.map(checks, &check!(&1, properties, verb))
  end

  defp check!(check, properties, verb) do
    field = if check.field, do: Atom.to_string(check.field)
    match = if check.match, do: Atom.to_string(check.match)
    refuse!(@check_rules, &check_refused?(&1, check, field, match, properties))

    %{"name" => to_string(check.name), "kind" => to_string(check.kind)}
    |> put_present("verb", check.verb && verb.(check.verb))
    |> put_present("scope", check.scope == :step && "step")
    |> Map.merge(if field, do: %{"field" => field, "equals" => check.equals}, else: %{})
    |> put_present("match", match)
  end

  defp check_refused?(:backend_identity, check, field, match, _properties),
    do: check.kind == :backend_equals and (is_nil(field) or is_nil(match))

  defp check_refused?(:known_identity, _check, _field, match, properties),
    do: match && !Map.has_key?(properties, match)

  defp check_refused?(:known_field, check, field, _match, properties),
    do: (check.kind in [:restored, :ui_equals] and field) && !Map.has_key?(properties, field)

  defp check_refused?(:ui_field, check, field, _match, _properties),
    do: check.kind == :ui_equals and is_nil(field)

  defp check_refused?(:restorable_field, check, field, _match, properties),
    do: (check.kind == :restored and field) && properties[field]["restore"] == false

  defp check_refused?(:scalar_equals, check, field, _match, _properties),
    do: field && !(is_boolean(check.equals) or is_number(check.equals) or is_binary(check.equals))

  defp check_refused?(:verb_only, check, field, match, _properties),
    do:
      check.kind in [:offered, :not_offered] == is_nil(check.verb) or
        (check.verb && (field || match))

  @criteria [:ui_equals, :backend_equals, :offered, :not_offered]

  @step_rules [
    record_of_verb: "on names the record of a verb step",
    direction: "swipe requires a direction, and only swipe takes one",
    bounded_keys: "step requires bounded widget keys and input references",
    until: "until references must name observed UI or backend criteria"
  ]

  defp steps(steps, checks, verb) do
    names = Enum.map(steps, & &1.name)

    if length(steps) > 32 or length(names) != length(Enum.uniq(names)),
      do: raise(ArgumentError, "journeys require at most 32 uniquely named steps")

    for check <- checks, check.scope == :step, do: observed_by_step!(check, steps)
    Enum.map(steps, &step!(&1, checks, verb))
  end

  defp observed_by_step!(check, steps) do
    unless check.kind in @criteria and Enum.any?(steps, &(check.name in &1.until)),
      do: raise(ArgumentError, "step checks must be observed by a declared step")
  end

  defp step!(step, checks, verb) do
    {kind, target} = step |> gestures() |> gesture!(step.from, verb)
    input = step.from || step.on
    refuse!(@step_rules, &step_refused?(&1, step, {kind, target, input}, checks))

    %{
      "name" => to_string(step.name),
      "kind" => kind,
      "target" => target,
      "until" => Enum.map(step.until, &to_string/1)
    }
    |> put_present("inputRef", input)
    |> put_present("verb", step.verb && String.replace_prefix(target, "verb:", ""))
    |> put_present("direction", step.direction && to_string(step.direction))
  end

  defp gestures(step) do
    [
      tap: step.tap,
      fill: step.fill,
      reveal: step.reveal,
      back: step.back,
      swipe: step.swipe,
      long_press: step.long_press,
      submit: step.submit,
      verb: step.verb
    ]
    |> Enum.reject(fn {_, value} -> value in [nil, false] end)
  end

  defp gesture!([{:fill, key}], from, _verb) when is_binary(from), do: {"fill", key}
  defp gesture!([{:back, true}], nil, _verb), do: {"back", "system.back"}
  defp gesture!([{:reveal, key}], nil, _verb), do: {"reveal", key}

  defp gesture!([{kind, key}], _from, _verb)
       when kind in [:tap, :swipe, :long_press, :submit] and is_binary(key),
       do: {to_string(kind), key}

  defp gesture!([{:verb, reference}], nil, verb), do: {"tap", "verb:" <> verb.(reference)}

  defp gesture!(_gestures, _from, _verb) do
    raise(
      ArgumentError,
      "step requires exactly one of tap, fill/from, reveal, back, swipe, long_press, submit or verb"
    )
  end

  defp step_refused?(:record_of_verb, step, _gesture, _checks), do: step.on && is_nil(step.verb)

  defp step_refused?(:direction, step, {kind, _target, _input}, _checks),
    do: kind == "swipe" == is_nil(step.direction)

  defp step_refused?(:bounded_keys, _step, {_kind, target, input}, _checks),
    do: not (bounded_key?(target) and (is_nil(input) or bounded_key?(input)))

  defp step_refused?(:until, step, _gesture, checks),
    do: not (length(step.until) in 0..32 and Enum.all?(step.until, &criterion?(checks, &1)))

  defp bounded_key?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9_.:-]{1,160}$/, value)

  defp criterion?(checks, name),
    do: Enum.any?(checks, &(&1.name == name and &1.kind in @criteria))

  # Rules are tried in order, so a declaration gets the first refusal that applies.
  defp refuse!(rules, refused?) do
    case Enum.find(rules, fn {rule, _message} -> refused?.(rule) end) do
      nil -> :ok
      {_rule, message} -> raise ArgumentError, message
    end
  end

  defp put_present(map, _key, value) when value in [nil, false], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
      unless valid_default?(properties[key], value),
        do: raise(ArgumentError, "#{key}: invalid moment default #{inspect(value)}")
    end)
  end

  defp valid_default?(%{"enum" => values}, value), do: value in values

  defp valid_default?(%{"type" => "string", "maxLength" => n}, value),
    do: is_binary(value) and utf16_length(value) <= n

  defp valid_default?(
         %{"type" => "object", "maxProperties" => n, "keyMaxLength" => k, "values" => bounds},
         value
       ),
       do: is_map(value) and map_size(value) <= n and Enum.all?(value, &rating?(&1, k, bounds))

  defp valid_default?(%{"min" => min, "max" => max}, value),
    do: is_number(value) and value >= min and value <= max

  defp rating?({key, rating}, key_max_length, bounds) do
    is_binary(key) and utf16_length(key) <= key_max_length and is_integer(rating) and
      rating >= bounds["min"] and rating <= bounds["max"]
  end
end
