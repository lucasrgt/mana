defmodule Mana.History do
  @moduledoc """
  Every change to a resource, recorded as it happens, as a by-product of the
  actions (and verbs) that make it:

      history do
        log MyApp.History.Entry
        redact [:counter_note]
      end

  After each create, update or destroy, the `log` resource (see
  `Mana.History.Log`) receives one entry: the subject, the action, who did it
  (`actor_kind` `user`, `system` when no actor or a `Mana.Entity` deadline
  ran it, `agent` when the action context carries `mana_agent: "<name>"`,
  kept in `via`), the inputs, the changed attributes before and after, and a
  sentence: the verb's `narrate:` when a `Mana.Verbs` verb performs the
  action, the action's name otherwise. An attempt that fails is recorded too,
  with `outcome: :failed` and its error code. Redacted and sensitive fields
  are kept as `"[redacted]"`; how long entries live is the log's own
  `retention` (`Mana.Resource`).

  Read a record's history with the log's `of` action; it answers only to
  whoever may read the record itself.
  """

  @history %Spark.Dsl.Section{
    name: :history,
    schema: [
      log: [type: :atom, required: true, doc: "The resource using `Mana.History.Log`."],
      redact: [type: {:list, :atom}, default: [], doc: "Inputs and attributes kept only as `[redacted]`."],
      ignore: [type: {:list, :atom}, default: [], doc: "Actions not recorded."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@history], transformers: [Mana.History.Transformer]
  use Mana.Primitive, contract: "x-mana-history", catalog: "history", moments: [:observe, :capture, :restore]

  @doc "Moments `observe`: the record's entries, oldest first (`export/3`)."
  def observe(log, subject_type, subject_id), do: export(log, subject_type, subject_id)

  @doc "Moments `capture`: the record's history as a portable fixture (`fixture/4`)."
  def capture(log, subject_type, subject_id, roles), do: fixture(log, subject_type, subject_id, roles)

  @doc "Moments `restore`: a captured history replayed into a new record (`replay/3`)."
  def restore(resource, entries, opts \\ []), do: replay(resource, entries, opts)
  require Ash.Query

  @redacted "[redacted]"

  def log(resource), do: Spark.Dsl.Extension.get_opt(resource, [:history], :log, nil)
  def redact(resource), do: Spark.Dsl.Extension.get_opt(resource, [:history], :redact, [])
  def ignore(resource), do: Spark.Dsl.Extension.get_opt(resource, [:history], :ignore, [])

  @impl Mana.Primitive
  def contract(resource) do
    log = log(resource)

    type =
      if Code.ensure_loaded?(AshJsonApi.Resource.Info) and AshJsonApi.Resource in Spark.extensions(log),
        do: to_string(AshJsonApi.Resource.Info.type(log))

    [%{"log" => type, "subject" => Mana.Entity.type(resource), "redacted" => Enum.map(redact(resource), &to_string/1)}]
  end

  @doc "The entries of `subject_type`/`subject_id` that `actor` may read, newest first."
  def of(log, subject_type, subject_id, actor) do
    log
    |> Ash.Query.for_read(:of, %{subject_type: subject_type, subject_id: to_string(subject_id)}, actor: actor)
    |> Ash.read!()
  end

  @doc """
  A record's history as plain maps, oldest first — what `replay/3` takes, and
  what a fixture file keeps to rebuild a situation (a Moment) elsewhere.
  """
  def export(log, subject_type, subject_id) do
    log
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter_input(%{subject_type: subject_type, subject_id: to_string(subject_id)})
    |> Ash.Query.sort(at: :asc)
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn entry ->
      %{
        "action" => entry.action,
        "verb" => entry.verb,
        "actor_id" => entry.actor_id,
        "actor_kind" => to_string(entry.actor_kind),
        "params" => entry.params,
        "outcome" => to_string(entry.outcome),
        "at" => DateTime.to_iso8601(entry.at),
        "trace" => entry.trace
      }
    end)
  end

  @doc """
  How the record stood at `at`, as `actor` may read it: its attributes now,
  with every change recorded after `at` undone from the entries' `before`
  (redacted values stay `"[redacted]"`). Nil when the actor may not read it.
  """
  def as_of(log, subject_type, subject_id, %DateTime{} = at, actor) do
    with subject when not is_nil(subject) <- Mana.History.Log.subject(log, subject_type),
         {:ok, record} <- Ash.get(subject, subject_id, actor: actor) do
      now =
        for attribute <- Ash.Resource.Info.public_attributes(subject), into: %{},
            do: {to_string(attribute.name), plain(Map.get(record, attribute.name))}

      log
      |> Ash.Query.filter(subject_type == ^subject_type and subject_id == ^to_string(subject_id) and outcome == :done and at > ^at)
      |> Ash.Query.sort(at: :desc)
      |> Ash.read!(authorize?: false)
      |> Enum.reduce(now, fn entry, state -> Map.merge(state, entry.before) end)
    else
      _ -> nil
    end
  end

  @doc """
  `export/3` made portable: each actor id becomes its role in `roles`
  (`%{user_id => "host"}`; unknown actors become `"system"`), so the entries
  can be committed as a fixture and replayed on fresh accounts — a Moment
  recipe maps the roles back with `replay(..., actor: %{"host" => host, ...})`.
  Only the subject's own actions are kept; notes replay nothing.
  """
  def fixture(log, subject_type, subject_id, roles) do
    actions = for action <- Ash.Resource.Info.actions(Mana.History.Log.subject(log, subject_type)), into: MapSet.new(), do: to_string(action.name)

    for entry <- export(log, subject_type, subject_id), entry["outcome"] == "done", MapSet.member?(actions, entry["action"]) do
      entry
      |> Map.put("actor_id", Map.get(roles, entry["actor_id"], "system"))
      |> Map.drop(["trace"])
    end
  end

  @doc """
  Rebuilds a record on `resource` by performing the done actions of `entries`
  (from `export/3` or `fixture/4`) again, in order: the first one creates
  it, the rest update it. `actor` (a function or a map) maps a recorded actor
  id or role to the actor that acts now
  (system entries act without one); `params` may fill or rewrite inputs per
  action (`fn action, params -> params end`) — redacted inputs cannot replay
  without it. Dates in the inputs move by how long ago the first entry
  happened (`times: :as_recorded` keeps them), so a recording keeps its
  relation to now. An entry whose verb is `external:` (Stripe, e-mail) refuses
  the replay with `:external`, or is passed over with `external: :skip`; notes
  (`note/3`: a delivery, a webhook) are what happened around it and replay nothing;
  other effects run as the environment runs them (fakes in development and
  tests). Answers `{:ok, record, applied}` or
  `{:error, %{at: index, action: action, error: error}}`.
  """
  def replay(resource, entries, opts \\ []) do
    actor =
      case Keyword.get(opts, :actor, fn _ -> nil end) do
        actors when is_map(actors) -> &Map.get(actors, &1)
        fun -> fun
      end

    params = Keyword.get(opts, :params, fn _action, params -> params end)
    offset = offset(entries, Keyword.get(opts, :times, :shift))
    external = for verb <- Mana.Verbs.declared(resource), verb.external, into: MapSet.new(), do: to_string(verb.name)
    skip_external? = Keyword.get(opts, :external) == :skip

    actions = for action <- Ash.Resource.Info.actions(resource), into: MapSet.new(), do: to_string(action.name)

    entries
    |> Enum.filter(&(&1["outcome"] == "done" and MapSet.member?(actions, &1["action"])))
    |> Enum.reject(&(skip_external? and MapSet.member?(external, &1["verb"])))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil, []}, fn {entry, index}, {:ok, record, applied} ->
      action = String.to_existing_atom(entry["action"])
      input = params.(action, shift(entry["params"] || %{}, offset))
      who = if entry["actor_kind"] == "user" and entry["actor_id"], do: actor.(entry["actor_id"])
      opts = [action: action, actor: who, authorize?: not is_nil(who)]

      result =
        cond do
          MapSet.member?(external, entry["verb"]) -> {:error, :external}
          Enum.any?(Map.values(input), &(&1 == @redacted)) -> {:error, :redacted_input}
          is_nil(record) -> resource |> Ash.Changeset.for_create(action, input, opts) |> Ash.create()
          true -> record |> Ash.Changeset.for_update(action, input, opts) |> Ash.update()
        end

      case result do
        {:ok, record} -> {:cont, {:ok, record, applied ++ [action]}}
        {:error, error} -> {:halt, {:error, %{at: index, action: action, error: error}}}
      end
    end)
  end

  # Replayed now, a recording keeps its relation to time: every date in the
  # inputs moves by how long ago the first entry happened, so a stay that
  # was two days ahead is two days ahead again and deadlines fall the same.
  defp offset(_entries, :as_recorded), do: 0

  defp offset(entries, :shift) do
    with [%{"at" => at} | _] when is_binary(at) <- entries,
         {:ok, first, _} <- DateTime.from_iso8601(at) do
      DateTime.diff(DateTime.utc_now(), first, :microsecond)
    else
      _ -> 0
    end
  end

  @doc false
  def shift(value, 0), do: value
  def shift(map, offset) when is_map(map), do: Map.new(map, fn {key, value} -> {key, shift(value, offset)} end)
  def shift(list, offset) when is_list(list), do: Enum.map(list, &shift(&1, offset))

  def shift(text, offset) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at |> DateTime.add(offset, :microsecond) |> DateTime.to_iso8601()
      _ -> text
    end
  end

  def shift(value, _offset), do: value

  @doc false
  def entry(changeset, record, outcome, error \\ nil) do
    resource = changeset.resource
    action = changeset.action
    context = changeset.context || %{}
    hidden = MapSet.new(redact(resource) ++ sensitive(resource, action))
    actor = context[:private][:actor]
    {kind, via} = author(actor, context)
    data = original(changeset)
    changed = if outcome == :done and record, do: changed(resource, data, record, action.type), else: []

    %{
      subject_type: Mana.Entity.type(resource),
      subject_id: subject_id(resource, record, changeset),
      action: to_string(action.name),
      verb: verb(resource, action.name),
      actor_id: actor && Map.get(actor, :id),
      actor_kind: kind,
      via: via,
      params: changeset |> inputs() |> redacted(hidden),
      before: if(action.type == :create, do: %{}, else: data |> Map.take(changed) |> redacted(hidden)),
      after: if(action.type == :destroy or is_nil(record), do: %{}, else: record |> Map.take(changed) |> redacted(hidden)),
      outcome: outcome,
      error: error,
      summary: summary(resource, action.name),
      trace: trace()
    }
  end

  @doc """
  Records something that happened to a record outside its own actions: a
  notice delivered, an e-mail the provider bounced, a code sent by SMS.
  `fields` names the `action` (a past-tense phrase is not needed: the
  `summary` is the sentence) and optionally `summary`, `after` (what is
  known about it), `outcome` (`:done`, or `:failed` with `error`) and `via`
  (who told us: `"notifications"`, `"webhook:resend"`). Recorded as `system`;
  a resource without history records nothing.
  """
  def note(resource, subject_id, fields) do
    if Mana.History in Spark.extensions(resource) and subject_id do
      action = to_string(Map.fetch!(fields, :action))

      Mana.History.Record.write(resource, %{
        subject_type: Mana.Entity.type(resource),
        subject_id: to_string(subject_id),
        action: action,
        verb: nil,
        actor_id: nil,
        actor_kind: :system,
        via: fields[:via],
        params: %{},
        before: %{},
        after: plain(fields[:after] || %{}),
        outcome: fields[:outcome] || :done,
        error: fields[:error],
        summary: fields[:summary] || String.replace(action, "_", " "),
        trace: trace()
      })
    end

    :ok
  end

  # The Moments gesture the change happened in, when one is being traced.
  defp trace do
    if Code.ensure_loaded?(Moments.ActionTrace) do
      case apply(Moments.ActionTrace, :get_span_context, []) do
        %{gesture: gesture} -> "gesture:#{gesture}"
        _ -> nil
      end
    end
  end

  defp subject_id(resource, record, changeset) do
    key =
      case Ash.Resource.Info.primary_key(resource) do
        [key] -> key
        _ -> :id
      end

    value = (record && Map.get(record, key)) || Map.get(original(changeset), key) || Map.get(changeset.attributes, key) || filtered(changeset, key)
    if is_nil(value), do: "unsaved", else: to_string(value)
  end

  # An atomic update that failed never loaded the record; its key is in the
  # filter it ran with.
  defp original(%{data: %Ash.Changeset.OriginalDataNotAvailable{}}), do: %{}
  defp original(changeset), do: changeset.data

  defp filtered(%{filter: %Ash.Filter{} = filter}, key) do
    case Ash.Filter.find_simple_equality_predicate(filter, key) do
      nil -> nil
      value -> value
    end
  rescue
    _ -> nil
  end

  defp filtered(_, _), do: nil

  defp author(actor, context) do
    cond do
      agent = context[:mana_agent] -> {:agent, to_string(agent)}
      deadline = context[:mana_deadline] -> {:system, "deadline:#{deadline}"}
      is_nil(actor) -> {:system, nil}
      true -> {:user, nil}
    end
  end

  defp inputs(changeset) do
    accepted = Map.new(changeset.action.accept || [], &{to_string(&1), &1})

    attributes =
      for {key, value} <- changeset.params || %{},
          name = accepted[to_string(key)],
          into: %{},
          do: {name, value}
    raw = Map.new(changeset.params || %{}, fn {key, value} -> {to_string(key), value} end)

    arguments =
      for argument <- changeset.action.arguments,
          argument.public?,
          Map.has_key?(changeset.arguments, argument.name),
          into: %{},
          do: {argument.name, Map.get(raw, to_string(argument.name), changeset.arguments[argument.name])}

    Map.merge(attributes, arguments)
  end

  defp changed(resource, _data, record, :create) do
    for attribute <- Ash.Resource.Info.public_attributes(resource),
        attribute.name not in [:id, :updated_at],
        not is_nil(Map.get(record, attribute.name)),
        do: attribute.name
  end

  defp changed(resource, data, record, _type) do
    for attribute <- Ash.Resource.Info.public_attributes(resource),
        Map.get(data, attribute.name) != Map.get(record, attribute.name),
        attribute.name not in [:updated_at],
        do: attribute.name
  end

  defp sensitive(resource, action) do
    attributes = for attribute <- Ash.Resource.Info.attributes(resource), attribute.sensitive?, do: attribute.name
    arguments = for argument <- action.arguments, argument.sensitive?, do: argument.name
    attributes ++ arguments
  end

  defp redacted(values, hidden) do
    Map.new(values, fn {key, value} ->
      {to_string(key), if(MapSet.member?(hidden, key), do: @redacted, else: plain(value))}
    end)
  end

  @doc false
  def encode(value), do: plain(value)

  defp plain(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp plain(%Date{} = value), do: Date.to_iso8601(value)
  defp plain(%Decimal{} = value), do: Decimal.to_string(value)
  defp plain(%_{} = value), do: value |> Map.from_struct() |> Map.drop([:__meta__, :__metadata__]) |> plain()
  defp plain(value) when is_map(value), do: Map.new(value, fn {k, v} -> {to_string(k), plain(v)} end)
  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: to_string(value)
  defp plain(value), do: value

  defp verb(resource, action) do
    if Mana.Verbs in Spark.extensions(resource) do
      case Enum.find(Mana.Verbs.declared(resource), &(Mana.Verbs.action(&1) == action)) do
        nil -> nil
        verb -> to_string(verb.name)
      end
    end
  end

  defp summary(resource, action) do
    narrated =
      if Mana.Verbs in Spark.extensions(resource),
        do: Enum.find_value(Mana.Verbs.declared(resource), &(Mana.Verbs.action(&1) == action && &1.narrate))

    narrated || action |> to_string() |> String.replace("_", " ")
  end

  @doc false
  def error_code(%{errors: [first | _]}), do: error_code(first)
  def error_code(%Mana.Error{code: code}), do: code
  def error_code(%{class: class}) when is_atom(class), do: to_string(class)
  def error_code(%module{}), do: module |> Module.split() |> List.last() |> Macro.underscore()
  def error_code(_), do: "error"
end

defmodule Mana.History.Record do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    cond do
      changeset.action.name in Mana.History.ignore(changeset.resource) ->
        changeset

      # Inside a caller's transaction a failure rolls back with it; only
      # successes are recorded there.
      Ash.DataLayer.in_transaction?(changeset.resource) ->
        Ash.Changeset.after_action(changeset, fn changeset, record ->
          write(changeset.resource, Mana.History.entry(changeset, record, :done))
          {:ok, record}
        end)

      true ->
        changeset
        |> Ash.Changeset.after_action(fn changeset, record ->
          write(changeset.resource, Mana.History.entry(changeset, record, :done))
          {:ok, record}
        end)
        |> Ash.Changeset.after_transaction(fn
          changeset, {:error, error} ->
            entry = Mana.History.entry(changeset, nil, :failed, Mana.History.error_code(error))
            write(changeset.resource, Map.put(entry, :report, report(changeset.resource, entry, error)))
            {:error, error}

          _changeset, result ->
            result
        end)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  require Logger

  # A failure the domain did not decide (a crash, a provider down) goes to
  # the app's error reporter (`config :mana_core, :error_reporter, {Mod, :fun}`,
  # e.g. Sentry) with the record it happened to; the entry keeps the report's
  # id, so each side leads to the other.
  defp report(resource, entry, error) do
    with {module, function} <- Application.get_env(:mana_core, :error_reporter),
         %Ash.Error.Unknown{} = unknown <- Ash.Error.to_error_class(error) do
      apply(module, function, [%{resource: resource, subject_type: entry.subject_type, subject_id: entry.subject_id, action: entry.action, actor_kind: entry.actor_kind}, unknown])
    else
      _ -> nil
    end
  end

  # The same entries feed analytics and the warehouse: one telemetry event
  # per change, labelled with the feature of the verb that made it.
  defp announce(resource, entry) do
    feature =
      if Mana.Verbs in Spark.extensions(resource),
        do: Enum.find_value(Mana.Verbs.declared(resource), &(to_string(&1.name) == entry[:verb] && &1.feature))

    :telemetry.execute([:mana, :history, :entry], %{count: 1}, %{
      resource: resource,
      subject_type: entry.subject_type,
      action: entry.action,
      verb: entry[:verb],
      feature: feature,
      outcome: entry.outcome,
      actor_kind: entry.actor_kind
    })
  end

  # A Moments journey links each gesture's request to the records it changed.
  defp trace(resource, entry) do
    if Code.ensure_loaded?(Moments.ActionTrace) and function_exported?(Moments.ActionTrace, :annotate_change, 1) do
      apply(Moments.ActionTrace, :annotate_change, [
        %{
          resource: resource,
          subject: entry.subject_id,
          action: entry.action,
          outcome: to_string(entry.outcome),
          fields: Enum.uniq(Map.keys(entry.before) ++ Map.keys(entry.after))
        }
      ])
    end
  end

  # The history never decides whether the change happens: a failure to
  # record is logged, not raised into the action.
  @doc false
  def write(resource, entry) do
    trace(resource, entry)
    announce(resource, entry)

    case resource |> Mana.History.log() |> Ash.Changeset.for_create(:record, entry) |> Ash.create(authorize?: false) do
      {:ok, _} -> :ok
      {:error, error} -> Logger.error("Mana.History could not record #{inspect(resource)}.#{entry.action}: #{Exception.message(error)}")
    end
  end
end

defmodule Mana.History.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(_), do: true

  def transform(dsl) do
    if Transformer.get_option(dsl, [:history], :log),
      do: Ash.Resource.Builder.add_change(dsl, Mana.History.Record, on: [:create, :update, :destroy]),
      else: {:ok, dsl}
  end
end

defmodule Mana.History.Log do
  @moduledoc """
  Makes a resource the history log of the resources that name it in
  `history do log ... end`:

      use Ash.Resource, extensions: [Mana.History.Log, Mana.Resource], ...

      history_log do
        subjects [MyApp.Booking]
      end

      retention do
        delete_after :at, days: 365
      end

  It adds the entry attributes and the actions `record` (used by
  `Mana.History`) and `of` (a record's entries, newest first, empty unless the
  actor may read that record). Expose `of` over JSON:API as you would any read.
  """

  @log %Spark.Dsl.Section{
    name: :history_log,
    schema: [subjects: [type: {:list, :atom}, required: true, doc: "The resources whose history this log keeps."]]
  }

  use Spark.Dsl.Extension, sections: [@log], transformers: [Mana.History.Log.Transformer]

  def subjects(log), do: Spark.Dsl.Extension.get_opt(log, [:history_log], :subjects, [])

  @doc "The subject resource whose `Mana.Entity.type/1` is `type`."
  def subject(log, type), do: Enum.find(subjects(log), &(Mana.Entity.type(&1) == type))
end

defmodule Mana.History.Log.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder

  def before?(_), do: true

  def transform(dsl) do
    fields = [:subject_type, :subject_id, :action, :verb, :actor_id, :actor_kind, :via, :params, :before, :after, :outcome, :error, :summary, :trace, :report]

    with {:ok, dsl} <- Builder.add_new_attribute(dsl, :id, :uuid, primary_key?: true, allow_nil?: false, writable?: false, default: &Ash.UUID.generate/0, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :subject_type, :string, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :subject_id, :string, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :action, :string, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :verb, :string, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :actor_id, :uuid, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :actor_kind, :atom, allow_nil?: false, public?: true, constraints: [one_of: [:user, :system, :agent]]),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :via, :string, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :params, :map, allow_nil?: false, default: %{}, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :before, :map, allow_nil?: false, default: %{}, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :after, :map, allow_nil?: false, default: %{}, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :outcome, :atom, allow_nil?: false, public?: true, constraints: [one_of: [:done, :failed]]),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :error, :string, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :summary, :string, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :trace, :string, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :report, :string, public?: true),
         {:ok, dsl} <- Builder.add_new_create_timestamp(dsl, :at, type: :utc_datetime_usec, public?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :create, :record, accept: fields),
         {:ok, dsl} <- Builder.add_new_action(dsl, :destroy, :destroy, primary?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :update, :forget, accept: [:actor_id, :via], require_atomic?: false),
         {:ok, dsl} <- Builder.add_new_action(dsl, :read, :read, primary?: true),
         {:ok, type} <- Builder.build_action_argument(:subject_type, :string, allow_nil?: false),
         {:ok, id} <- Builder.build_action_argument(:subject_id, :string, allow_nil?: false),
         {:ok, readable} <- Builder.build_preparation(Mana.History.Readable),
         {:ok, dsl} <- Builder.add_new_action(dsl, :read, :of, arguments: [type, id], preparations: [readable]),
         {:ok, at} <- Builder.build_action_argument(:at, :string, allow_nil?: false, description: "An ISO 8601 moment, e.g. 2026-10-08T12:00:00Z.") do
      Builder.add_new_action(dsl, :action, :as_of,
        returns: :map,
        arguments: [type, id, at],
        run: {Mana.History.AsOf, []}
      )
    end
  end
end

defmodule Mana.History.AsOf do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, context) do
    with {:ok, at, _} <- DateTime.from_iso8601(input.arguments.at),
         state when state != nil <- Mana.History.as_of(input.resource, input.arguments.subject_type, input.arguments.subject_id, at, context.actor) do
      {:ok, state}
    else
      {:error, _} -> {:error, Ash.Error.Changes.InvalidArgument.exception(field: :at, message: "is not an ISO 8601 moment")}
      nil -> {:error, Ash.Error.Query.NotFound.exception(resource: input.resource)}
    end
  end
end

defmodule Mana.History.Readable do
  @moduledoc false
  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, _opts, context) do
    type = Ash.Query.get_argument(query, :subject_type)
    id = Ash.Query.get_argument(query, :subject_id)
    subject = Mana.History.Log.subject(query.resource, type)

    readable? =
      subject != nil and
        match?({:ok, _}, Ash.get(subject, id, actor: context.actor, tenant: context.tenant, authorize?: context.authorize? != false))

    if readable?,
      do: query |> Ash.Query.filter(subject_type == ^type and subject_id == ^id) |> Ash.Query.sort(at: :desc),
      else: Ash.Query.filter(query, false)
  end
end
