defmodule Mana.Incident do
  @moduledoc """
  A production incident as a Moment: a record's history up to a moment,
  with the records it references, anonymized into a portable fixture that a
  recipe replays on fresh accounts (`mix mana.incident booking:<id> --at <iso>`).

      incident = Mana.Incident.export([MyApp.Bookings], "booking", id, at: at)
      File.write!(path, Mana.Incident.encode(incident))

      recipe :booking_incident, "The booking of the 30th, rebuilt.", data_scope: true do
        {:ok, booking, _records} =
          Mana.Incident.replay(path, [MyApp.Bookings], %{"person-1" => host, "person-2" => traveler})
        ...
      end

  Collected: the subject's entries (`Mana.History.export/3`) up to `at`, and,
  transitively, those of every record a `belongs_to` names whose resource
  keeps history and has entries by then; each record's state at `at` is its
  done entries' `after` folded in order. References are found where the
  history kept them (a public attribute or an input).

  ## Format `mana.incident/1`

      {"format": "mana.incident/1", "at": "<iso>", "subject": "booking-1",
       "roles": ["person-1", "person-2"],
       "records": [{"ref": "place-1", "type": "place", "entries": [...], "state": {...}},
                   {"ref": "booking-1", "type": "booking", ...}]}

  Records come referenced first, so each one's references are rebuilt
  before it. Entries are `Mana.History.export/3`'s without `trace`, with
  `actor_id` as a role (as `Mana.History.fixture/4`). In `params` and
  `state`, a collected record's id reads `[record:<ref>]`, a person's id
  `[actor:<role>]`, a personal value `[personal:<field>:<n>]` (equal values
  share one); `"[redacted]"` is the history's own. Keys are sorted, so the
  same history encodes to the same bytes.

  ## Anonymization

  Property: the fixture holds no personal value of a collected record.
  `guaranteed` within the declarations: every value of a field the
  resource declares personal (privacy `export`, history `redact`), every
  actor id, every value of the privacy `subject` and of a `belongs_to` to
  an identity resource (one whose privacy subject is its primary key), and
  every string equal to one of those wherever it appears, are replaced.
  `reviewed`: personal data a resource does not declare, or carries in
  another field without ever showing it in a declared one, leaves as it
  is — check the declarations before committing a fixture. People get roles
  in order of appearance (`person-1`, ...) unless `roles:` names them.
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
    context = %{resources: resources(domains), at: at}
    subject = {type, to_string(id)}

    unless Map.has_key?(context.resources, type),
      do: raise(ArgumentError, "no resource with history of type #{inspect(type)}")

    records = subject |> visit(context, {MapSet.new(), []}) |> elem(1) |> Enum.reverse()

    unless Enum.any?(records, &({&1.type, &1.id} == subject)),
      do: raise(ArgumentError, "#{type}:#{id} has no history up to #{DateTime.to_iso8601(at)}")

    roles = Map.new(Keyword.get(opts, :roles, %{}), fn {id, role} -> {to_string(id), role} end)
    names = names(records, roles)

    %{
      "format" => @format,
      "at" => DateTime.to_iso8601(at),
      "subject" => Map.fetch!(names.refs, elem(subject, 1)),
      "roles" => names.roles |> Map.values() |> Enum.uniq() |> Enum.sort(),
      "records" => Enum.map(records, &anonymize(&1, names))
    }
  end

  @doc "The incident as JSON, keys sorted."
  def encode(incident), do: incident |> ordered() |> Jason.encode!(pretty: true)

  @doc """
  Rebuilds an incident (a fixture path or an `export/4` map) through
  `Mana.History.replay/3`, record by record, on whatever database the
  caller runs on — inside a `data_scope: true` recipe, its scope. `actors`
  maps each role to the actor that acts now; a role without one acts as
  the system and its id is a fresh UUID. Personal values become stand-ins
  of the input's type (`guest_email-1@example.invalid`, `name-1`, `1`).
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

    context = %{
      resources: resources(domains),
      actors: actors,
      identities: Map.new(incident["roles"], &{&1, identity(Map.get(actors, &1))}),
      offset: offset(incident, Keyword.get(opts, :times, :shift)),
      params: Keyword.get(opts, :params, fn _ref, _action, params -> params end),
      external: Keyword.get(opts, :external)
    }

    incident["records"]
    |> Enum.reduce_while({:ok, %{}}, &rebuild(&1, &2, context))
    |> case do
      {:ok, rebuilt} -> {:ok, Map.get(rebuilt, incident["subject"]), rebuilt}
      error -> error
    end
  end

  defp resources(domains) do
    for domain <- List.wrap(domains),
        resource <- Ash.Domain.Info.resources(domain),
        History in Spark.extensions(resource),
        into: %{},
        do: {Mana.Entity.type(resource), resource}
  end

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

    state =
      log
      |> Ash.Query.filter(
        subject_type == ^type and subject_id == ^id and outcome == :done and at <= ^at
      )
      |> Ash.Query.sort(at: :asc)
      |> Ash.read!(authorize?: false)
      |> Enum.reduce(%{}, &Map.merge(&2, &1.after))

    %{resource: resource, type: type, id: id, entries: entries, state: state}
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

  # Every value `field` held in the record's state and its entries' inputs.
  defp inputs(record, field) do
    key = to_string(field)
    from_entries = Enum.map(record.entries, &(&1["params"] || %{})[key])
    Enum.reject([record.state[key] | from_entries], &is_nil/1)
  end

  defp names(records, roles) do
    refs =
      records
      |> Enum.map_reduce(%{}, fn record, counts ->
        n = Map.get(counts, record.type, 0) + 1
        {{record.id, "#{record.type}-#{n}"}, Map.put(counts, record.type, n)}
      end)
      |> elem(0)
      |> Map.new()

    %{
      refs: refs,
      roles: name_people(Enum.flat_map(records, &people/1), roles),
      personal: number_personal(Enum.flat_map(records, &personal_values/1))
    }
  end

  defp people(record) do
    actors = for entry <- record.entries, entry["actor_id"], do: entry["actor_id"]
    actors ++ Enum.flat_map(identity_fields(record.resource), &inputs(record, &1))
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
  defp personal_values(record) do
    fields = personal_fields(record.resource)
    maps = Enum.map(record.entries, &(&1["params"] || %{})) ++ [record.state]
    Enum.flat_map(maps, &occurrences(&1, nil, fields))
  end

  defp occurrences(value, key, fields) do
    cond do
      MapSet.member?(fields, key) and personal?(value) ->
        [{key, value}]

      is_map(value) ->
        value |> Enum.sort() |> Enum.flat_map(fn {k, v} -> occurrences(v, k, fields) end)

      is_list(value) ->
        Enum.flat_map(value, &occurrences(&1, key, fields))

      true ->
        []
    end
  end

  defp personal?(value), do: value not in [nil, "", @redacted]

  defp personal_fields(resource) do
    exported =
      if Mana.Resource in Spark.extensions(resource),
        do: Mana.Resource.Info.privacy_export!(resource),
        else: []

    MapSet.new(exported ++ History.redact(resource), &to_string/1)
  end

  # The privacy subject, and every reference to a person's own row.
  defp identity_fields(resource) do
    subject = privacy_subject(resource)

    references =
      for relationship <- Info.relationships(resource),
          relationship.type == :belongs_to,
          identity?(relationship.destination),
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

  defp anonymize(record, names) do
    fields = personal_fields(record.resource)

    entries =
      for entry <- record.entries do
        entry
        |> Map.put("actor_id", entry["actor_id"] && Map.fetch!(names.roles, entry["actor_id"]))
        |> Map.put("params", rewrite(entry["params"] || %{}, nil, fields, names))
      end

    %{
      "ref" => Map.fetch!(names.refs, record.id),
      "type" => record.type,
      "entries" => entries,
      "state" => rewrite(record.state, nil, fields, names)
    }
  end

  defp rewrite(value, key, fields, names) when is_binary(value) do
    cond do
      Map.has_key?(names.refs, value) -> "[record:#{names.refs[value]}]"
      Map.has_key?(names.roles, value) -> "[actor:#{names.roles[value]}]"
      MapSet.member?(fields, key) and personal?(value) -> Map.fetch!(names.personal, value)
      true -> Map.get(names.personal, value, value)
    end
  end

  defp rewrite(value, key, fields, names) do
    cond do
      MapSet.member?(fields, key) and personal?(value) ->
        Map.fetch!(names.personal, value)

      is_map(value) ->
        Map.new(value, fn {k, v} -> {k, rewrite(v, k, fields, names)} end)

      is_list(value) ->
        Enum.map(value, &rewrite(&1, key, fields, names))

      true ->
        value
    end
  end

  defp ordered(map) when is_map(map),
    do:
      map
      |> Enum.sort()
      |> Enum.map(fn {key, value} -> {key, ordered(value)} end)
      |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  defp load(%{"format" => @format} = incident), do: incident
  defp load(path) when is_binary(path), do: path |> File.read!() |> Jason.decode!() |> load()

  defp load(other),
    do: raise(ArgumentError, "not a #{@format} incident: #{inspect(other, limit: 3)}")

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

  defp rebuild(record, {:ok, rebuilt}, context) do
    ref = record["ref"]

    with {:ok, resource} <- Map.fetch(context.resources, record["type"]),
         entries =
           Enum.map(record["entries"], &resolve_entry(&1, ref, resource, rebuilt, context)),
         {:ok, built, _applied} <-
           History.replay(resource, entries,
             actor: context.actors,
             times: :as_recorded,
             external: context.external
           ) do
      {:cont, {:ok, if(built, do: Map.put(rebuilt, ref, built), else: rebuilt)}}
    else
      :error -> {:halt, {:error, %{record: ref, error: :unknown_type}}}
      {:error, failure} -> {:halt, {:error, Map.put(failure, :record, ref)}}
    end
  end

  # Notes name no action of the resource; replay passes over them.
  defp resolve_entry(entry, ref, resource, rebuilt, context) do
    case Enum.find(Info.actions(resource), &(to_string(&1.name) == entry["action"])) do
      nil ->
        entry

      action ->
        types =
          Map.merge(
            Map.new(Info.attributes(resource), &{to_string(&1.name), &1.type}),
            Map.new(action.arguments, &{to_string(&1.name), &1.type})
          )

        params =
          for {key, value} <- History.shift(entry["params"] || %{}, context.offset),
              into: %{},
              do: {key, resolve(value, Map.get(types, key), rebuilt, context)}

        Map.put(entry, "params", context.params.(ref, action.name, params))
    end
  end

  defp resolve(map, _type, rebuilt, context) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, resolve(value, nil, rebuilt, context)} end)

  defp resolve(list, {:array, type}, rebuilt, context),
    do: Enum.map(list, &resolve(&1, type, rebuilt, context))

  defp resolve(list, type, rebuilt, context) when is_list(list),
    do: Enum.map(list, &resolve(&1, type, rebuilt, context))

  defp resolve(value, type, rebuilt, context) when is_binary(value) do
    case Regex.run(@marker, value) do
      [_, "record", ref | _] -> rebuilt |> Map.get(ref) |> then(&(&1 && &1.id))
      [_, "actor", role | _] -> Map.get(context.identities, role)
      [_, "personal", field, n] -> stand_in_for(type, field, String.to_integer(n))
      _ -> value
    end
  end

  defp resolve(value, _type, _rebuilt, _context), do: value

  defp stand_in_for({:array, type}, field, n), do: [stand_in_for(type, field, n)]
  defp stand_in_for(nil, field, n), do: stand_in(nil, field, n)
  defp stand_in_for(type, field, n), do: stand_in(Ash.Type.get_type(type), field, n)

  defp stand_in(Ash.Type.Integer, _field, n), do: n
  defp stand_in(Ash.Type.Float, _field, n), do: n * 1.0
  defp stand_in(Ash.Type.Decimal, _field, n), do: Decimal.new(n)
  defp stand_in(Ash.Type.Boolean, _field, _n), do: false
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
