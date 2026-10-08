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
  use Mana.Primitive, contract: "x-mana-history", catalog: "history", moments: [:observe]

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
  `export/3` made portable: each actor id becomes its role in `roles`
  (`%{user_id => "host"}`; unknown actors become `"system"`), so the entries
  can be committed as a fixture and replayed on fresh accounts — a Moment
  recipe maps the roles back with `replay(..., actor: %{"host" => host, ...})`.
  """
  def fixture(log, subject_type, subject_id, roles) do
    for entry <- export(log, subject_type, subject_id), entry["outcome"] == "done" do
      entry
      |> Map.put("actor_id", Map.get(roles, entry["actor_id"], "system"))
      |> Map.drop(["trace", "at"])
    end
  end

  @doc """
  Rebuilds a record on `resource` by performing the done actions of `entries`
  (from `export/3` or `fixture/4`) again, in order: the first one creates
  it, the rest update it. `actor` (a function or a map) maps a recorded actor
  id or role to the actor that acts now
  (system entries act without one); `params` may fill or rewrite inputs per
  action (`fn action, params -> params end`) — redacted inputs cannot replay
  without it. An entry whose verb is `external:` (Stripe, e-mail) refuses
  the replay with `:external`, or is passed over with `external: :skip`;
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
    external = for verb <- Mana.Verbs.declared(resource), verb.external, into: MapSet.new(), do: to_string(verb.name)
    skip_external? = Keyword.get(opts, :external) == :skip

    entries
    |> Enum.filter(&(&1["outcome"] == "done"))
    |> Enum.reject(&(skip_external? and MapSet.member?(external, &1["verb"])))
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, nil, []}, fn {entry, index}, {:ok, record, applied} ->
      action = String.to_existing_atom(entry["action"])
      input = params.(action, entry["params"] || %{})
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
            write(changeset.resource, Mana.History.entry(changeset, nil, :failed, Mana.History.error_code(error)))
            {:error, error}

          _changeset, result ->
            result
        end)
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  require Logger

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
  defp write(resource, entry) do
    trace(resource, entry)

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
    fields = [:subject_type, :subject_id, :action, :verb, :actor_id, :actor_kind, :via, :params, :before, :after, :outcome, :error, :summary, :trace]

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
         {:ok, dsl} <- Builder.add_new_create_timestamp(dsl, :at, type: :utc_datetime_usec, public?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :create, :record, accept: fields),
         {:ok, dsl} <- Builder.add_new_action(dsl, :destroy, :destroy, primary?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :update, :forget, accept: [:actor_id, :via], require_atomic?: false),
         {:ok, dsl} <- Builder.add_new_action(dsl, :read, :read, primary?: true),
         {:ok, type} <- Builder.build_action_argument(:subject_type, :string, allow_nil?: false),
         {:ok, id} <- Builder.build_action_argument(:subject_id, :string, allow_nil?: false),
         {:ok, readable} <- Builder.build_preparation(Mana.History.Readable) do
      Builder.add_new_action(dsl, :read, :of, arguments: [type, id], preparations: [readable])
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
