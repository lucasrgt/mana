defmodule Mana.Incident do
  @moduledoc """
  A production incident as a Moment: a record's history up to a moment,
  with the records it references, anonymized into a portable fixture that a
  recipe replays on fresh accounts (`mix mana.incident booking:<id> --at <iso>`).

      incident = Mana.Incident.export([MyApp.Bookings], "booking", id, at: at)
      File.write!(path, Mana.Incident.encode(incident))

      recipe :booking_incident, "The booking of the 30th, rebuilt.", data_scope: true do
        {:ok, booking, _records} =
          Mana.Incident.replay(path, [MyApp.Bookings], %{"host" => host},
            person: fn _role, person -> MyApp.Factory.user(person.attributes) end)
        ...
      end

  Collected: the subject's entries (`Mana.History.export/3`) up to `at`, and,
  transitively, those of every record a `belongs_to` names whose resource
  keeps history and has entries by then; each record's state at `at` is its
  done entries' `after` folded in order. References are found where the
  history kept them (a public attribute, an input or the seed). A record
  whose history starts with an update was created outside its actions (a
  seed, a data migration): its row as it stood before that update
  (`Mana.History.seed_state/4`) is kept as its `seed`, which replay writes
  as it is instead of performing a create the history never had.

  People are not records: a row of an identity resource (one whose privacy
  subject is its primary key, a user) is never collected or replayed. Every
  person — an actor of an entry, the privacy subject, a `belongs_to` to an
  identity resource — is a role (`roles:` names them, the rest are
  `person-1`, `person-2`, ... in order of appearance), and each person's
  row, when an identity resource of the domains has it, is kept under
  `people` with its personal fields replaced, so a stand-in can be made
  like them (a host stays a host).

  ## Format `mana.incident/1`

      {"format": "mana.incident/1", "at": "<iso>", "subject": "booking-1",
       "roles": ["host", "person-1"],
       "people": [{"role": "host", "type": "user", "state": {...}}],
       "records": [{"ref": "place-1", "type": "place", "entries": [...], "state": {...}},
                   {"ref": "booking-1", "type": "booking", ..., "seed": {...}}]}

  Records come referenced first; `seed` is there only for a record whose
  history starts with an update. Entries are `Mana.History.export/3`'s
  without `trace`, with `actor_id` as a role (as `Mana.History.fixture/4`).
  In `params`, `state` and `seed`, a collected record's id reads
  `[record:<ref>]`, a person's id `[actor:<role>]`, a personal value
  `[personal:<field>:<n>]` (equal values share one); `"[redacted]"` is the
  history's own. Keys are sorted, so the same history encodes to the same
  bytes.

  ## Anonymization

  Property: the fixture holds no personal value of a collected record or
  person. `guaranteed` within the declarations: every value of a field the
  resource declares personal (`Mana.Privacy.personal/1`: privacy `personal`,
  or every `export` field when it is not given, and history `redact`),
  every person's id, and every string equal to a personal string wherever
  it appears in a field that can hold text (not an enum, atom or boolean),
  are replaced. Values that cannot identify anyone (booleans, empty values)
  are left, so are business fields that are only exported (a status, a
  total, the lines): the situation stays. `reviewed`: personal data a
  resource does not declare, or carries in another field without ever
  showing it in a declared one, leaves as it is — check the declarations
  before committing a fixture. A person's row is read as it is now, or as of
  `at` from its history when its resource keeps one.
  """

  require Ash.Query

  alias Ash.Resource.Info
  alias Mana.History

  @format "mana.incident/1"
  @redacted "[redacted]"
  @marker ~r/^\[(record|actor|personal):([^\]:]+)(?::(\d+))?\]$/

  @doc """
  The incident of `type`/`id` as of `at:` (default now), anonymized.
  `roles:` (`%{user_id => "host"}`) names people; the rest are numbered.
  The logs are read with authorization off: an operator's path, not a
  user's.
  """
  def export(domains, type, id, opts \\ []) do
    at = Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)
    context = %{resources: resources(domains), people: identity_resources(domains), at: at}
    subject = {type, to_string(id)}

    unless Map.has_key?(context.resources, type),
      do: raise(ArgumentError, "no resource with history of type #{inspect(type)}")

    records = subject |> visit(context, {MapSet.new(), []}) |> elem(1) |> Enum.reverse()

    unless Enum.any?(records, &({&1.type, &1.id} == subject)),
      do: raise(ArgumentError, "#{type}:#{id} has no history up to #{DateTime.to_iso8601(at)}")

    roles = Map.new(Keyword.get(opts, :roles, %{}), fn {id, role} -> {to_string(id), role} end)
    names = names(records, roles, context)

    %{
      "format" => @format,
      "at" => DateTime.to_iso8601(at),
      "subject" => Map.fetch!(names.refs, elem(subject, 1)),
      "roles" => names.roles |> Map.values() |> Enum.uniq() |> Enum.sort(),
      "people" => Enum.map(names.people, &anonymize_person(&1, names)),
      "records" => Enum.map(records, &anonymize(&1, names))
    }
  end

  @doc "The incident as JSON, keys sorted."
  def encode(incident), do: incident |> ordered() |> Jason.encode!(pretty: true)

  @doc """
  Rebuilds an incident (a fixture path or an `export/4` map) through
  `Mana.History.replay_all/2` on whatever database the caller runs on —
  inside a `data_scope: true` recipe, its scope. The entries of all the
  records are performed in the order they were recorded, not record by
  record, so a step that needed another record's later state (publishing
  a place once its service is published) finds it again.

  Each role is one person, the same wherever the fixture names it (an
  entry's actor, a `host_id`): `actors` maps a role to the actor that acts
  now, and `person:` (`fn role, person -> actor end`) makes a stand-in for
  a role `actors` leaves out, once per role, from what the fixture kept of
  the person (`%{role:, type:, resource:, attributes:}`, personal values as
  stand-ins). A role the records reference that ends with no actor fails
  the replay before anything is rebuilt (`error: :no_person`): a fresh id
  there would point at no one. A role that only acts acts as the system.

  Personal values become stand-ins of the field's type
  (`guest_email-1@example.invalid`, `name-1`, `1`, an enum's first value).
  Options: `params` (`fn ref, action, params -> params end`, after the
  stand-ins; redacted inputs need it), `times` and `external` as for
  `Mana.History.replay/3` (dates move by how long ago the incident began).
  Answers `{:ok, subject, %{ref => record}}` or
  `{:error, %{record: ref, at: index, action: action, error: error}}`; the
  records rebuilt before a failure stay, so run it where the data is
  disposable (a data scope, a test).
  """
  def replay(source, domains, actors, opts \\ []) do
    incident = load(source)
    resources = resources(domains)

    with {:ok, actors} <- people(incident, identity_resources(domains), actors, opts[:person]) do
      context = %{
        resources: resources,
        actors: actors,
        identities: Map.new(incident["roles"], &{&1, identity(Map.get(actors, &1))}),
        offset: offset(incident, Keyword.get(opts, :times, :shift)),
        params: Keyword.get(opts, :params, fn _ref, _action, params -> params end),
        external: Keyword.get(opts, :external)
      }

      with {:ok, histories} <- histories(incident["records"], context),
           context = Map.put(context, :kinds, Map.new(histories, &{&1.key, &1.resource})),
           {:ok, rebuilt, _applied} <-
             History.replay_all(histories,
               actor: context.actors,
               times: :as_recorded,
               external: context.external,
               params: &resolve_params(&1, &2, &3, &4, context)
             ) do
        {:ok, Map.get(rebuilt, incident["subject"]), rebuilt}
      else
        {:error, %{key: ref} = failure} ->
          {:error, failure |> Map.delete(:key) |> Map.put(:record, ref)}

        error ->
          error
      end
    end
  end

  defp resources(domains) do
    for domain <- List.wrap(domains),
        resource <- Ash.Domain.Info.resources(domain),
        History in Spark.extensions(resource),
        not identity?(resource),
        into: %{},
        do: {Mana.Entity.type(resource), resource}
  end

  defp identity_resources(domains) do
    for domain <- List.wrap(domains),
        resource <- Ash.Domain.Info.resources(domain),
        identity?(resource),
        uniq: true,
        do: resource
  end

  # ---------------------------------------------------------------------------
  # Collecting

  # Depth first, references before the record that names them; a reference
  # without history up to `at` is left as its id.
  defp visit({type, id} = key, context, {seen, records}) do
    if MapSet.member?(seen, key) do
      {seen, records}
    else
      record = read(Map.fetch!(context.resources, type), id, context.at)

      {seen, records} =
        record
        |> references(context.resources)
        |> Enum.reduce({MapSet.put(seen, key), records}, &visit(&1, context, &2))

      if record.entries == [], do: {seen, records}, else: {seen, [record | records]}
    end
  end

  defp read(resource, id, at) do
    log = History.log(resource)
    type = Mana.Entity.type(resource)

    entries =
      for entry <- History.export(log, type, id),
          {:ok, entry_at, _} = DateTime.from_iso8601(entry["at"]),
          DateTime.compare(entry_at, at) != :gt,
          do: Map.delete(entry, "trace")

    seed =
      if History.starts_with_update?(resource, entries),
        do: History.seed_state(resource, id, current(resource, id))

    %{
      resource: resource,
      type: type,
      id: id,
      entries: entries,
      seed: seed,
      state: Map.merge(seed || %{}, state(log, type, id, at))
    }
  end

  defp state(log, type, id, at) do
    log
    |> Ash.Query.filter(
      subject_type == ^type and subject_id == ^id and outcome == :done and at <= ^at
    )
    |> Ash.Query.sort(at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(%{}, &Map.merge(&2, &1.after))
  end

  defp references(record, resources) do
    for relationship <- Info.relationships(record.resource),
        relationship.type == :belongs_to,
        destination = relationship.destination,
        type = Mana.Entity.type(destination),
        Map.get(resources, type) == destination,
        value <- inputs(record, relationship.source_attribute),
        is_binary(value),
        uniq: true,
        do: {type, value}
  end

  # Every value `field` held in the record's state, seed and entries' inputs.
  defp inputs(record, field) do
    key = to_string(field)
    from_entries = Enum.map(record.entries, &(&1["params"] || %{})[key])
    Enum.reject([record.state[key], (record.seed || %{})[key] | from_entries], &is_nil/1)
  end

  # ---------------------------------------------------------------------------
  # Naming

  defp names(records, roles, context) do
    refs =
      records
      |> Enum.map_reduce(%{}, fn record, counts ->
        n = Map.get(counts, record.type, 0) + 1
        {{record.id, "#{record.type}-#{n}"}, Map.put(counts, record.type, n)}
      end)
      |> elem(0)
      |> Map.new()

    roles = name_people(Enum.flat_map(records, &people_of(&1, context.people)), roles)
    people = rows(roles, context)

    %{
      refs: refs,
      roles: roles,
      people: people,
      personal:
        number_personal(
          Enum.flat_map(records, &personal_values(&1.resource, maps(&1))) ++
            Enum.flat_map(people, &personal_values(&1.resource, [&1.state]))
        )
    }
  end

  defp maps(record),
    do: Enum.map(record.entries, &(&1["params"] || %{})) ++ [record.state, record.seed || %{}]

  defp people_of(record, identities) do
    actors = for entry <- record.entries, entry["actor_id"], do: entry["actor_id"]
    actors ++ Enum.flat_map(identity_fields(record.resource, identities), &inputs(record, &1))
  end

  defp name_people(ids, roles) do
    ids
    |> Enum.uniq()
    |> Enum.reduce({%{}, 0}, fn id, {named, n} ->
      case Map.fetch(roles, id) do
        {:ok, role} -> {Map.put(named, id, role), n}
        :error -> {Map.put(named, id, "person-#{n + 1}"), n + 1}
      end
    end)
    |> elem(0)
  end

  # Each named person's row, from the first identity resource that has it.
  defp rows(roles, context) do
    for {id, role} <- Enum.sort_by(roles, &elem(&1, 1)),
        {resource, state} <- [row(context.people, id, context.at)],
        resource,
        do: %{role: role, resource: resource, type: Mana.Entity.type(resource), state: state}
  end

  defp row(resources, id, at) do
    Enum.find_value(resources, {nil, nil}, fn resource ->
      case person_state(resource, id, at) do
        state when state == %{} -> nil
        state -> {resource, state}
      end
    end)
  end

  defp person_state(resource, id, at) do
    recorded =
      if History in Spark.extensions(resource),
        do: state(History.log(resource), Mana.Entity.type(resource), id, at),
        else: %{}

    state = if recorded == %{}, do: current(resource, id), else: recorded
    [key] = Info.primary_key(resource)

    state
    |> Map.delete(to_string(key))
    |> Map.reject(fn {_field, value} -> value == @redacted end)
  end

  defp current(resource, id) do
    case Ash.get(resource, id, authorize?: false, error?: false) do
      {:ok, %{} = row} ->
        for attribute <- Info.public_attributes(resource),
            not attribute.sensitive?,
            into: %{},
            do: {to_string(attribute.name), History.encode(Map.get(row, attribute.name))}

      _ ->
        %{}
    end
  end

  defp number_personal(occurrences) do
    occurrences
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.reduce({%{}, %{}}, fn {field, value}, {table, counts} ->
      n = Map.get(counts, field, 0) + 1
      {Map.put(table, value, "[personal:#{field}:#{n}]"), Map.put(counts, field, n)}
    end)
    |> elem(0)
  end

  # In the order the anonymized fixture lists them, so numbering is stable.
  defp personal_values(resource, maps) do
    fields = personal_fields(resource)

    for map <- maps,
        {field, value} <- Enum.sort(map),
        MapSet.member?(fields, field),
        leaf <- personal_leaves(value),
        do: {field, leaf}
  end

  defp personal_leaves(value) when is_map(value),
    do: value |> Enum.sort() |> Enum.flat_map(&personal_leaves(elem(&1, 1)))

  defp personal_leaves(value) when is_list(value), do: Enum.flat_map(value, &personal_leaves/1)
  defp personal_leaves(value), do: if(personal?(value), do: [value], else: [])

  # What can say who someone is: text and numbers, not a flag or an empty value.
  defp personal?(value) when is_binary(value), do: value not in ["", @redacted]
  defp personal?(value), do: is_number(value)

  defp personal_fields(resource), do: MapSet.new(Mana.Privacy.personal(resource))

  # The privacy subject, and every reference to a person's own row.
  defp identity_fields(resource, identities) do
    subject = privacy_subject(resource)

    references =
      for relationship <- Info.relationships(resource),
          relationship.type == :belongs_to,
          relationship.destination in identities or identity?(relationship.destination),
          do: relationship.source_attribute

    Enum.reject([subject | references], &is_nil/1)
  end

  defp identity?(resource),
    do:
      privacy_subject(resource) != nil and
        Info.primary_key(resource) == [privacy_subject(resource)]

  defp privacy_subject(resource) do
    with true <- Mana.Resource in Spark.extensions(resource),
         {:ok, subject} <- Mana.Resource.Info.privacy_subject(resource),
         do: subject,
         else: (_ -> nil)
  end

  # ---------------------------------------------------------------------------
  # Anonymizing

  defp anonymize(record, names) do
    attributes = types(record.resource)
    personal = personal_fields(record.resource)

    entries =
      for entry <- record.entries do
        types = Map.merge(attributes, arguments(record.resource, entry["action"]))

        entry
        |> Map.put("actor_id", entry["actor_id"] && Map.fetch!(names.roles, entry["actor_id"]))
        |> Map.put("params", fields(entry["params"] || %{}, types, personal, names))
      end

    anonymized = %{
      "ref" => Map.fetch!(names.refs, record.id),
      "type" => record.type,
      "entries" => entries,
      "state" => fields(record.state, attributes, personal, names)
    }

    if record.seed,
      do: Map.put(anonymized, "seed", fields(record.seed, attributes, personal, names)),
      else: anonymized
  end

  defp anonymize_person(person, names) do
    %{
      "role" => person.role,
      "type" => person.type,
      "state" =>
        fields(person.state, types(person.resource), personal_fields(person.resource), names)
    }
  end

  defp fields(map, types, personal, names) do
    Map.new(map, fn {field, value} ->
      type = Map.get(types, field)

      if MapSet.member?(personal, field),
        do: {field, personal(value, names)},
        else: {field, plain(value, type, names)}
    end)
  end

  defp personal(value, names) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {key, personal(inner, names)} end)

  defp personal(value, names) when is_list(value), do: Enum.map(value, &personal(&1, names))

  defp personal(value, names),
    do: if(personal?(value), do: plain(value, nil, names, true), else: value)

  defp plain(value, type, names, personal? \\ false)

  defp plain(value, type, names, personal?) when is_binary(value) do
    cond do
      Map.has_key?(names.roles, value) -> "[actor:#{names.roles[value]}]"
      Map.has_key?(names.refs, value) -> "[record:#{names.refs[value]}]"
      personal? -> Map.fetch!(names.personal, value)
      fixed?(type) -> value
      true -> Map.get(names.personal, value, value)
    end
  end

  defp plain(value, _type, names, true), do: Map.fetch!(names.personal, value)

  defp plain(value, type, names, false) when is_list(value),
    do: Enum.map(value, &plain(&1, element(type), names))

  defp plain(value, type, names, false) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {key, plain(inner, inner_type(type, key), names)} end)

  defp plain(value, _type, _names, false), do: value

  defp types(resource), do: Map.new(Info.attributes(resource), &{to_string(&1.name), &1.type})

  defp arguments(resource, action) do
    case Enum.find(Info.actions(resource), &(to_string(&1.name) == action)) do
      nil -> %{}
      action -> Map.new(action.arguments, &{to_string(&1.name), &1.type})
    end
  end

  # A field whose values are a fixed set holds no one's text.
  defp fixed?(nil), do: false
  defp fixed?({:array, type}), do: fixed?(type)

  defp fixed?(type) do
    type = Ash.Type.get_type(type)

    type in [Ash.Type.Atom, Ash.Type.Boolean] or
      (Code.ensure_loaded?(type) and function_exported?(type, :values, 0))
  end

  defp element({:array, type}), do: type
  defp element(_type), do: nil

  defp inner_type(nil, _key), do: nil

  defp inner_type(type, key) do
    type = Ash.Type.get_type(type)

    if Ash.Type.embedded_type?(type),
      do: Map.get(types(type), to_string(key)),
      else: nil
  end

  defp ordered(map) when is_map(map),
    do:
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
      |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  # ---------------------------------------------------------------------------
  # Replaying

  defp load(%{"format" => @format} = incident), do: incident
  defp load(path) when is_binary(path), do: path |> File.read!() |> Jason.decode!() |> load()

  defp load(other),
    do: raise(ArgumentError, "not a #{@format} incident: #{inspect(other, limit: 3)}")

  # Every role gets its actor before anything is rebuilt: one per role, made
  # once, so every reference to the person names the same row.
  defp people(incident, identities, actors, make) do
    kept = Map.new(incident["people"] || [], &{&1["role"], &1})
    referenced = referenced_roles(incident)

    Enum.reduce_while(incident["roles"], {:ok, actors}, fn role, {:ok, actors} ->
      cond do
        Map.has_key?(actors, role) ->
          {:cont, {:ok, actors}}

        make ->
          {:cont,
           {:ok,
            Map.put(actors, role, make.(role, stand_in_person(kept[role], role, identities)))}}

        MapSet.member?(referenced, role) ->
          {:halt, {:error, %{role: role, error: :no_person}}}

        true ->
          {:cont, {:ok, actors}}
      end
    end)
  end

  defp stand_in_person(nil, role, _identities),
    do: %{role: role, type: nil, resource: nil, attributes: %{}}

  defp stand_in_person(person, role, identities) do
    resource = Enum.find(identities, &(Mana.Entity.type(&1) == person["type"]))
    types = if resource, do: types(resource), else: %{}

    %{
      role: role,
      type: person["type"],
      resource: resource,
      attributes:
        Map.new(person["state"], fn {field, value} ->
          {field, resolve(value, Map.get(types, field), %{}, %{identities: %{}})}
        end)
    }
  end

  defp referenced_roles(incident) do
    for record <- incident["records"],
        map <- [
          record["state"],
          record["seed"] || %{} | Enum.map(record["entries"], &(&1["params"] || %{}))
        ],
        [_, "actor", role | _] <- map |> strings() |> Enum.map(&Regex.run(@marker, &1)),
        into: MapSet.new(),
        do: role
  end

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(_value), do: []

  defp identity(%{id: id}) when not is_nil(id), do: to_string(id)
  defp identity(_), do: Ash.UUID.generate()

  # One offset for every record, so their dates keep their relation to each other.
  defp offset(_incident, :as_recorded), do: 0

  defp offset(incident, :shift) do
    incident["records"]
    |> Enum.flat_map(& &1["entries"])
    |> Enum.map(&DateTime.from_iso8601(&1["at"]))
    |> Enum.flat_map(fn
      {:ok, at, _} -> [at]
      _ -> []
    end)
    |> Enum.min(DateTime, fn -> nil end)
    |> case do
      nil -> 0
      first -> DateTime.diff(DateTime.utc_now(), first, :microsecond)
    end
  end

  defp histories(records, context) do
    Enum.reduce_while(Enum.reverse(records), {:ok, []}, fn record, {:ok, histories} ->
      case Map.fetch(context.resources, record["type"]) do
        {:ok, resource} -> {:cont, {:ok, [history(record, resource, context) | histories]}}
        :error -> {:halt, {:error, %{record: record["ref"], error: :unknown_type}}}
      end
    end)
  end

  # References resolve when the entry is performed, against the records
  # rebuilt by then: in recorded order, a record is rebuilt before any entry
  # that names it.
  defp history(record, resource, context) do
    seed = record["seed"] && (&fields_now(record["seed"], types(resource), &1, context))
    %{key: record["ref"], resource: resource, entries: record["entries"], seed: seed}
  end

  defp resolve_params(ref, action, params, rebuilt, context) do
    resource = Map.fetch!(context.kinds, ref)
    types = Map.merge(types(resource), arguments(resource, to_string(action)))
    context.params.(ref, action, fields_now(params, types, rebuilt, context))
  end

  defp fields_now(map, types, rebuilt, context) do
    for {key, value} <- History.shift(map, context.offset),
        into: %{},
        do: {key, resolve(value, Map.get(types, key), rebuilt, context)}
  end

  defp resolve(map, type, rebuilt, context) when is_map(map),
    do:
      Map.new(map, fn {key, value} ->
        {key, resolve(value, inner_type(type, key), rebuilt, context)}
      end)

  defp resolve(list, type, rebuilt, context) when is_list(list),
    do: Enum.map(list, &resolve(&1, element(type) || type, rebuilt, context))

  defp resolve(value, type, rebuilt, context) when is_binary(value) do
    case Regex.run(@marker, value) do
      [_, "record", ref | _] -> rebuilt |> Map.get(ref) |> then(&(&1 && &1.id))
      [_, "actor", role | _] -> Map.get(context.identities, role)
      [_, "personal", field, n] -> stand_in_for(type, field, String.to_integer(n))
      _ -> value
    end
  end

  defp resolve(value, _type, _rebuilt, _context), do: value

  defp stand_in_for({:array, type}, field, n), do: stand_in_for(type, field, n)
  defp stand_in_for(nil, field, n), do: stand_in(nil, field, n)
  defp stand_in_for(type, field, n), do: stand_in(Ash.Type.get_type(type), field, n)

  defp stand_in(Ash.Type.Integer, _field, n), do: n
  defp stand_in(Ash.Type.Float, _field, n), do: n * 1.0
  defp stand_in(Ash.Type.Decimal, _field, n), do: Decimal.new(n)
  defp stand_in(Ash.Type.Date, _field, n), do: Date.add(~D[2000-01-01], n)
  defp stand_in(Ash.Type.UUID, _field, _n), do: Ash.UUID.generate()

  defp stand_in(type, _field, n)
       when type in [Ash.Type.UtcDatetime, Ash.Type.UtcDatetimeUsec, Ash.Type.DateTime],
       do: DateTime.add(~U[2000-01-01 00:00:00Z], n, :day)

  defp stand_in(type, field, n) do
    cond do
      Code.ensure_loaded?(type) and function_exported?(type, :values, 0) -> hd(type.values())
      String.contains?(field, "email") -> "#{field}-#{n}@example.invalid"
      true -> "#{field}-#{n}"
    end
  end
end
