defmodule Mana.Verbs.Verb do
  @moduledoc false
  defstruct [:name, :action, :when, :unavailable, :collection, :from, :risk, :external, :confirm, :inverse, :idempotent, :feature, :describe, :narrate, :retry, :offline, :knob, :because, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Verbs do
  @moduledoc """
  The actions a record offers right now, declared once next to them:

      verbs do
        verb :accept, when: expr(status in [:requested, :proposal_sent]), idempotent: true
        verb :pay, when: expr(status == :accepted), risk: :money
        verb :apply_coupon, when: expr(status == :open), inverse: :remove_coupon
      end

  Each record gets a public `verbs` calculation: the verbs whose `when` holds
  for it and whose action the actor's policies allow. Clients render only
  those (Flutter `VerbButton`); the API still enforces policies and
  validations on every call, so `verbs` is guidance for the interface and for
  agents, never the authorization itself.

  A `collection: true` verb is offered with no record of its own resource:
  creating one, or acting on the person's account. With `from: {Parent,
  :field}` it is offered by a parent record — the parent's `verbs` lists it
  as `"<type>.<verb>"` and its `when` is an expression over that parent
  (`verb :request, collection: true, from: {MyApp.Service, :service_id},
  when: expr(public == true)`); without `from` its `when` is `{Module,
  :fun}`(actor) and `available/2` answers it. A create action is refused on
  the server when its collection verb does not hold; a generic action calls
  `allowed/4` first. The server refuses a verb's action
  on a record its `when` does not hold for, with the domain error named by
  `unavailable` (`verb.unavailable` otherwise), so the rule is written once;
  an `idempotent` verb is let through, since repeating it changes nothing. `risk`, `inverse`, `idempotent` and
  `feature` reach the contract as `x-mana-verbs` on the resource schema
  (`Mana.Domain.OpenApi.finish/2`).
  """

  @verb %Spark.Dsl.Entity{
    name: :verb,
    target: Mana.Verbs.Verb,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true, doc: "The verb; the action of the same name unless `action` says otherwise."],
      action: [type: :atom, doc: "The resource action the verb performs."],
      when: [
        type: :any,
        doc:
          "An expression over the record (and `^actor(...)`); the verb is offered, and its action accepted, only while it holds. A collection verb may name `{Module, :fun}` instead: (parent, actor) with `from`, (actor) without."
      ],
      unavailable: [
        type: {:or, [:atom, {:tuple, [:atom, :atom]}]},
        doc: "The domain error (`Mana.Domain` `errors`) answered when `when` does not hold; a collection verb may name `{Module, :fun}` (parent or nil, actor) returning the precise one."
      ],
      collection: [type: :boolean, default: false, doc: "Offered with no record of this resource: creating one, or acting on the person's account."],
      from: [type: {:tuple, [:atom, :atom]}, doc: "`{Parent, :field}`: a collection verb a parent record offers; `field` carries its id and `when` looks at it."],
      risk: [type: {:in, [:none, :money, :destructive]}, default: :none, doc: "Clients confirm before `:money` and `:destructive`."],
      external: [
        type: :string,
        doc: "The outside system its action reaches (\"stripe\", \"email\", \"sms\"): what it does there cannot be rolled back, so agent checkpoints refuse it and `Mana.History.replay` refuses or skips it."
      ],
      confirm: [type: :boolean, default: false, doc: "Clients ask before running it even when it risks nothing (a decision worth a second look)."],
      inverse: [type: :atom, doc: "The verb that undoes this one, offered as Undo."],
      idempotent: [type: :boolean, default: false, doc: "Repeating it with the same input has no further effect."],
      feature: [type: :string, doc: "The `feature:<name>` it belongs to (features.toml)."],
      describe: [type: :string, doc: "One line for interfaces and agents."],
      narrate: [type: :string, doc: "How `Mana.History` tells it happened (\"cancelled the booking\")."],
      retry: [type: :non_neg_integer, default: 0, doc: "Times a client resends it after a transient failure; only for idempotent verbs."],
      because: [type: :string, doc: "The notebook note (`mana note`) that decided this rule; `mana doctor` checks it exists."],
      knob: [type: :atom, doc: "A boolean `Mana.Knobs` knob (`config :mana_core, :knobs, MyApp.Knobs`) that must be on for the actor."],
      offline: [
        type: {:in, [:reject, :queue]},
        default: :reject,
        doc: "Without a network, `:queue` keeps it for later (idempotent verbs, never money); `:reject` fails at once."
      ]
    ]
  }

  @verbs %Spark.Dsl.Section{
    name: :verbs,
    imports: [Ash.Expr],
    entities: [@verb],
    schema: [calculation: [type: :atom, default: :verbs, doc: "The name of the calculation that lists the offered verbs."]]
  }

  use Spark.Dsl.Extension, sections: [@verbs], transformers: [Mana.Verbs.Transformer, Mana.Verbs.Validate]
  use Mana.Primitive, contract: "x-mana-verbs", catalog: "verbs", moments: [:observe]

  @doc "Moments `observe`: what `record` offers `actor` now."
  def observe(record, actor), do: %{"offered" => offered(record, actor)}

  def declared(resource), do: Spark.Dsl.Extension.get_entities(resource, [:verbs])
  def calculation(resource), do: Spark.Dsl.Extension.get_opt(resource, [:verbs], :calculation, :verbs)
  def action(%Mana.Verbs.Verb{action: nil, name: name}), do: name
  def action(%Mana.Verbs.Verb{action: action}), do: action

  @doc "The names of the verbs `record` offers `actor` now, its children's collection verbs as `type.verb`."
  def offered(record, actor, opts \\ []) do
    resource = record.__struct__

    own =
      for verb <- declared(resource),
          not verb.collection,
          knob_on?(verb, actor),
          holds?(verb, record, resource, actor),
          flow_allows?(resource, record, verb),
          allowed?(verb, record, actor, opts),
          do: to_string(verb.name)

    related =
      for {child, verb} <- children(resource),
          knob_on?(verb, actor),
          holds?(verb, record, resource, actor),
          can_create?(child, verb, %{elem(verb.from, 1) => record.id}, actor),
          do: "#{Mana.Entity.type(child)}.#{verb.name}"

    own ++ related
  end

  @doc "The record-less collection verbs `actor` may perform now across `domains`, as `type.verb`."
  def available(domains, actor) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        Mana.Verbs in Spark.extensions(resource),
        verb <- declared(resource),
        verb.collection and is_nil(verb.from),
        knob_on?(verb, actor),
        precondition?(verb, actor),
        can_create?(resource, verb, %{}, actor),
        do: "#{Mana.Entity.type(resource)}.#{verb.name}"
  end

  @doc """
  `:ok` when `actor` may perform collection verb `name` of `resource` with
  `input` now, or the error its declaration names; generic actions call it
  before they act (create actions are gated on their own).
  """
  def allowed(resource, name, actor, input \\ %{}) do
    verb = verb!(resource, name)

    cond do
      not knob_on?(verb, actor) -> {:error, Mana.Error.new("feature.disabled", "this is turned off right now", status: 403)}
      collection_holds?(resource, verb, actor, input) -> :ok
      true -> {:error, refusal(resource, verb, actor, input)}
    end
  end

  @doc false
  def refusal(resource, %{unavailable: {module, function}, from: from}, actor, input) do
    parent =
      with {parent, field} <- from,
           id when not is_nil(id) <- input[field] || input[to_string(field)],
           {:ok, record} <- Ash.get(parent, id, authorize?: false) do
        record
      else
        _ -> nil
      end

    apply(module, function, [parent, actor]) || unavailable(resource, %{unavailable: nil, name: :verb})
  end

  def refusal(resource, verb, _actor, _input), do: unavailable(resource, verb)

  @doc false
  def collection_holds?(_resource, %{from: {parent, field}} = verb, actor, input) do
    with id when not is_nil(id) <- input[field] || input[to_string(field)],
         {:ok, record} <- Ash.get(parent, id, authorize?: false) do
      holds?(verb, record, parent, actor)
    else
      _ -> false
    end
  end

  def collection_holds?(_resource, verb, actor, _input), do: precondition?(verb, actor)

  @doc false
  def unavailable(_resource, %{unavailable: nil, name: name}),
    do: Mana.Error.new("verb.unavailable", "#{name} is not available now", status: 422)

  def unavailable(resource, %{unavailable: error}), do: Ash.Resource.Info.domain(resource).error(error)

  defp precondition?(%{when: nil}, _actor), do: true
  defp precondition?(%{when: {module, function}}, actor), do: apply(module, function, [actor]) == true

  defp can_create?(resource, verb, input, actor) do
    Ash.can?({resource, action(verb), input}, actor, run_queries?: false, maybe_is: false, return_forbidden_error?: false)
  rescue
    _ -> false
  end

  @doc false
  # The collection verbs other resources of the app declare `from` this one.
  def children(resource) do
    key = {__MODULE__, :children, resource}

    case :persistent_term.get(key, nil) do
      nil ->
        app = Application.get_application(resource)
        domains = Enum.uniq([Ash.Resource.Info.domain(resource) | (app && Application.get_env(app, :ash_domains, [])) || []])

        found =
          for domain <- domains,
              child <- Ash.Domain.Info.resources(domain),
              Mana.Verbs in Spark.extensions(child),
              verb <- declared(child),
              verb.collection and match?({^resource, _}, verb.from),
              do: {child, verb}

        :persistent_term.put(key, found)
        found

      found ->
        found
    end
  end

  @doc false
  def knob_on?(verb, actor) do
    knobs = Application.get_env(:mana_core, :knobs)

    (is_nil(verb.knob) or Mana.Knobs.enabled?(Application.fetch_env!(:mana_core, :knobs), verb.knob, actor)) and
      (is_nil(knobs) or is_nil(verb.feature) or Mana.Knobs.feature_on?(knobs, verb.feature, actor))
  end

  defp holds?(%{when: nil}, _record, _resource, _actor), do: true
  defp holds?(%{when: {module, function}}, record, _resource, actor), do: apply(module, function, [record, actor]) == true

  defp holds?(%{when: expression}, record, resource, actor) do
    match?({:ok, true}, Ash.Expr.eval(condition(expression, actor), record: record, resource: resource))
  end

  @doc false
  def condition(expression, actor), do: Ash.Expr.fill_template(expression, actor: actor)

  # A step of a `Mana.Flow` is offered once the flow reached it; the flow
  # itself refuses it before.
  defp flow_allows?(resource, record, verb),
    do: not (Mana.Flow in Spark.extensions(resource)) or Mana.Flow.may_run?(record, action(verb))

  defp allowed?(verb, record, actor, opts) do
    Ash.can?({record, action(verb)}, actor,
      run_queries?: false,
      maybe_is: false,
      tenant: opts[:tenant],
      return_forbidden_error?: false
    )
  rescue
    _ -> false
  end

  @doc """
  Performs `steps` (`{record, verb, params}`) in order as `actor`. When one
  fails, the steps already done are undone through their verbs' `inverse`,
  newest first, and the answer says which failed and what was compensated;
  a done step without an inverse is reported in `uncompensated`.
  """
  def run_all(steps, actor) do
    Enum.reduce_while(Enum.with_index(steps), [], fn {{record, name, params}, index}, done ->
      verb = verb!(record.__struct__, name)

      case Ash.update(record, params, action: action(verb), actor: actor) do
        {:ok, updated} -> {:cont, [{updated, verb} | done]}
        {:error, error} -> {:halt, {:failed, index, error, done}}
      end
    end)
    |> case do
      {:failed, index, error, done} ->
        {compensated, uncompensated} =
          Enum.reduce(done, {[], []}, fn {record, verb}, {compensated, uncompensated} ->
            with inverse when not is_nil(inverse) <- verb.inverse,
                 {:ok, undone} <- Ash.update(record, %{}, action: action(verb!(record.__struct__, inverse)), actor: actor) do
              {[undone | compensated], uncompensated}
            else
              _ -> {compensated, [record | uncompensated]}
            end
          end)

        {:error, %{failed: index, error: error, compensated: Enum.reverse(compensated), uncompensated: Enum.reverse(uncompensated)}}

      done ->
        {:ok, done |> Enum.reverse() |> Enum.map(&elem(&1, 0))}
    end
  end

  defp verb!(resource, name),
    do: Enum.find(declared(resource), &(&1.name == name)) || raise(ArgumentError, "#{inspect(resource)} declares no verb #{inspect(name)}")

  @doc """
  The AVP archetypes that verify a verb, from what it declares: its action
  sits behind policies (`authorization`), and a `when` the server enforces is
  a `lifecycle-gate` (an idempotent verb is let through, so it claims none).
  Money moved and replay safety are not claimed here: AVP's
  `money-integrity` checks a split endpoint and `request-idempotency` a
  keyed create, neither of which a verb is.
  """
  def archetypes(%Mana.Verbs.Verb{collection: true} = verb) do
    ["authorization"] ++ if(verb.when && verb.from, do: ["lifecycle-gate"], else: [])
  end

  def archetypes(%Mana.Verbs.Verb{} = verb) do
    ["authorization"] ++ if(verb.when && not verb.idempotent, do: ["lifecycle-gate"], else: [])
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
          names = for(verb <- declared(resource), action(verb) == route.action, do: "#{Mana.Entity.type(resource)}.#{verb.name}"),
          names != [],
          into: %{},
          do: {route.name, names}

    Map.update(spec, "paths", %{}, fn paths ->
      Map.new(paths, fn {path, operations} ->
        {path,
         Map.new(operations, fn
           {method, %{"operationId" => id} = operation} when is_map_key(marks, id) -> {method, Map.put(operation, "x-mana-verb", marks[id])}
           other -> other
         end)}
      end)
    end)
  end

  @impl Mana.Primitive
  def contract(resource) do
    for verb <- declared(resource) do
      %{
        "name" => to_string(verb.name),
        "action" => to_string(action(verb)),
        "risk" => to_string(verb.risk),
        "idempotent" => verb.idempotent,
        "confirm" => verb.confirm or verb.risk != :none,
        "retry" => verb.retry,
        "offline" => to_string(verb.offline),
        "archetypes" => archetypes(verb)
      }
      |> then(&if verb.inverse, do: Map.put(&1, "inverse", to_string(verb.inverse)), else: &1)
      |> then(&if verb.feature, do: Map.put(&1, "feature", verb.feature), else: &1)
      |> then(&if verb.describe, do: Map.put(&1, "describe", verb.describe), else: &1)
      |> then(&if verb.because, do: Map.put(&1, "because", verb.because), else: &1)
      |> then(&if verb.external, do: Map.put(&1, "external", verb.external), else: &1)
      |> then(&if verb.collection, do: Map.put(&1, "collection", true), else: &1)
      |> then(fn map ->
        case verb.from do
          {parent, field} -> Map.merge(map, %{"from" => Mana.Entity.type(parent), "field" => to_string(field)})
          nil -> map
        end
      end)
      |> Map.put("inputs", inputs(resource, action(verb)))
    end
  end

  @doc """
  What a verb's action takes, with the rules the server enforces, so a client
  checks the same ones before sending: each accepted public attribute and
  public argument with its `type`, whether it is `required`, and the
  constraints that apply (`min_length`, `max_length`, `match`, `min`, `max`,
  `one_of`, and `format` for `Mana.BR` types and UUIDs), and `unique` when
  a single-attribute identity of the resource makes it so. The server stays
  authoritative and answers each failure on its field.
  """
  def inputs(resource, action_name) do
    action = Ash.Resource.Info.action(resource, action_name)

    attributes =
      for name <- Map.get(action, :accept) || [],
          attribute = Ash.Resource.Info.attribute(resource, name),
          attribute.public?,
          do: {attribute, action.type == :create and not attribute.allow_nil? and is_nil(attribute.default) and name not in (Map.get(action, :allow_nil_input) || [])}

    arguments = for argument <- action.arguments, argument.public?, do: {argument, not argument.allow_nil? and is_nil(argument.default)}

    unique = for identity <- Ash.Resource.Info.identities(resource), [key] <- [identity.keys], into: MapSet.new(), do: key

    for {field, required} <- attributes ++ arguments do
      %{"name" => to_string(field.name), "required" => required}
      |> Map.merge(rules(field.type, field.constraints || []))
      |> then(&if MapSet.member?(unique, field.name), do: Map.put(&1, "unique", true), else: &1)
    end
  end

  defp rules({:array, type}, constraints) do
    items = rules(type, constraints[:items] || [])

    %{"type" => "array", "items" => items}
    |> put("min_length", constraints[:min_length])
    |> put("max_length", constraints[:max_length])
  end

  defp rules(type, constraints) do
    type = Ash.Type.get_type(type)

    cond do
      function_exported?(type, :format, 0) and match?("br-" <> _, safe_format(type)) ->
        %{"type" => "string", "format" => type.format()}

      type == Ash.Type.String or type == Ash.Type.CiString ->
        %{"type" => "string"}
        |> put("min_length", constraints[:min_length])
        |> put("max_length", constraints[:max_length])
        |> put("match", match_source(constraints[:match]))

      type == Ash.Type.Integer or type == Ash.Type.Float or type == Ash.Type.Decimal ->
        %{"type" => if(type == Ash.Type.Integer, do: "integer", else: "number")}
        |> put("min", number(constraints[:min]))
        |> put("max", number(constraints[:max]))

      type == Ash.Type.Boolean ->
        %{"type" => "boolean"}

      type == Ash.Type.UUID ->
        %{"type" => "string", "format" => "uuid"}

      type == Ash.Type.Atom and is_list(constraints[:one_of]) ->
        %{"type" => "string", "one_of" => Enum.map(constraints[:one_of], &to_string/1)}

      Ash.Type.NewType.new_type?(type) ->
        rules(Ash.Type.NewType.subtype_of(type), Keyword.merge(Ash.Type.NewType.constraints(type, constraints), constraints))

      function_exported?(type, :values, 0) ->
        %{"type" => "string", "one_of" => Enum.map(type.values(), &to_string/1)}

      Ash.Type.storage_type(type, constraints) in [:utc_datetime, :utc_datetime_usec, :naive_datetime, :naive_datetime_usec] ->
        %{"type" => "string", "format" => "date-time"}

      Ash.Type.storage_type(type, constraints) == :date ->
        %{"type" => "string", "format" => "date"}

      true ->
        %{"type" => "object"}
    end
  end

  defp safe_format(type) do
    type.format()
  rescue
    _ -> nil
  end

  defp match_source(%Regex{source: source}), do: source
  defp match_source({m, f, a}), do: match_source(apply(m, f, a))
  defp match_source(_), do: nil

  defp number(%Decimal{} = value), do: Decimal.to_float(value)
  defp number(value), do: value

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)
end

defmodule Mana.Verbs.Offered do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, context) do
    Enum.map(records, &Mana.Verbs.offered(&1, context.actor, tenant: context.tenant))
  end
end

defmodule Mana.Verbs.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  defp guard_generic(dsl, verbs) do
    for verb <- verbs, verb.collection, reduce: dsl do
      dsl ->
        name = Mana.Verbs.action(verb)

        case Enum.find(Transformer.get_entities(dsl, [:actions]), &(&1.name == name and &1.type == :action)) do
          %{run: {Mana.Verbs.Guarded, _}} ->
            dsl

          %{run: run} = action when not is_nil(run) ->
            guarded = %{action | run: {Mana.Verbs.Guarded, verb: verb.name, run: normalize(run)}}
            Transformer.replace_entity(dsl, [:actions], guarded, &(&1.name == name))

          _ ->
            dsl
        end
    end
  end

  defp normalize({module, opts}) when is_atom(module), do: {module, opts}
  defp normalize(module) when is_atom(module), do: {module, []}
  defp normalize(fun) when is_function(fun), do: {Ash.Resource.Actions.Implementation.Function, [fun: fun]}

  def before?(_), do: true

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:verbs]) do
      [] ->
        {:ok, dsl}

      _ ->
        name = Transformer.get_option(dsl, [:verbs], :calculation) || :verbs

        with {:ok, dsl} <-
               Ash.Resource.Builder.add_new_calculation(dsl, name, {:array, :string}, Mana.Verbs.Offered,
                 public?: true,
                 description: "The verbs this record offers the actor now."
               ) do
          verbs = Transformer.get_entities(dsl, [:verbs])

          with {:ok, dsl} <-
                 if(Enum.any?(verbs, &(&1.knob || &1.feature)),
                   do: Ash.Resource.Builder.add_change(dsl, Mana.Verbs.KnobGate, on: [:create, :update, :destroy]),
                   else: {:ok, dsl}
                 ) do
            dsl =
              if Enum.any?(verbs, & &1.collection) do
                {:ok, gate} = Transformer.build_entity(Ash.Resource.Dsl, [:validations], :validate, validation: Mana.Verbs.CollectionGate, on: [:create])
                dsl |> Transformer.add_entity([:validations], gate, type: :append) |> guard_generic(verbs)
              else
                dsl
              end

            if Enum.any?(verbs, &(&1.when && not &1.collection)) do
              with {:ok, gate} <- Transformer.build_entity(Ash.Resource.Dsl, [:validations], :validate, validation: Mana.Verbs.WhenGate, on: [:update, :destroy]),
                   dsl = Transformer.add_entity(dsl, [:validations], gate, type: :append),
                   do: Ash.Resource.Builder.add_change(dsl, Mana.Verbs.Recheck, on: [:update, :destroy])
            else
              {:ok, dsl}
            end
          end
        end
    end
  end
end

defmodule Mana.Verbs.Guarded do
  @moduledoc false
  # A generic action that performs a collection verb: the verb's condition is
  # checked before the action's own implementation runs.
  use Ash.Resource.Actions.Implementation

  # Several verbs may perform one action (`action:`): one offered from a
  # parent applies when its field is given, the record-less one otherwise.
  @impl true
  def run(input, opts, context) do
    verbs = for verb <- Mana.Verbs.declared(input.resource), verb.collection, Mana.Verbs.action(verb) == input.action.name, do: verb
    given = fn {_parent, field} -> not is_nil(input.arguments[field]) end
    applicable = Enum.filter(verbs, &(&1.from && given.(&1.from)))
    applicable = if applicable == [], do: Enum.filter(verbs, &is_nil(&1.from)), else: applicable

    case Enum.find(applicable, &(Mana.Verbs.allowed(input.resource, &1.name, context.actor, input.arguments) == :ok)) do
      nil when applicable == [] ->
        inner(input, opts, context)

      nil ->
        Mana.Verbs.allowed(input.resource, hd(applicable).name, context.actor, input.arguments)

      _ ->
        inner(input, opts, context)
    end
  end

  defp inner(input, opts, context) do
    {module, inner} = opts[:run]
    module.run(input, inner, context)
  end
end

defmodule Mana.Verbs.KnobGate do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    case Enum.find(Mana.Verbs.declared(changeset.resource), &(Mana.Verbs.action(&1) == changeset.action.name and (&1.knob || &1.feature))) do
      nil ->
        changeset

      verb ->
        if Mana.Verbs.knob_on?(verb, context.actor),
          do: changeset,
          else: Ash.Changeset.add_error(changeset, Mana.Error.new("feature.disabled", "this is turned off right now", status: 403))
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end

defmodule Mana.Verbs.WhenGate do
  @moduledoc false
  # Skipped once the changeset is already invalid, so an action's own state
  # check that answered first is not reported twice.
  use Ash.Resource.Validation
  require Ash.Expr

  @impl true
  def validate(changeset, _opts, context) do
    with %{} = verb <- verb(changeset),
         true <- changeset.valid?,
         {:ok, held} when held in [false, nil] <-
           Ash.Expr.eval(Mana.Verbs.condition(verb.when, context.actor), record: changeset.data, resource: changeset.resource) do
      {:error, unavailable(changeset.resource, verb)}
    else
      _ -> :ok
    end
  end

  @impl true
  def atomic(changeset, _opts, context) do
    case verb(changeset) do
      nil ->
        :ok

      verb ->
        fields = for {k, v} <- Map.take(unavailable(changeset.resource, verb), [:code, :message, :status, :field]), v != nil, into: %{}, do: {k, v}
        {:atomic, [], Ash.Expr.expr(not (^Mana.Verbs.condition(verb.when, context.actor))), Ash.Expr.expr(error(Mana.Error, ^fields))}
    end
  end

  # An idempotent verb repeated has no further effect, so it is not refused.
  defp verb(changeset),
    do: Enum.find(Mana.Verbs.declared(changeset.resource), &(Mana.Verbs.action(&1) == changeset.action.name and not is_nil(&1.when) and not &1.idempotent and not &1.collection))

  defp unavailable(resource, verb), do: Mana.Verbs.unavailable(resource, verb)
end

defmodule Mana.Verbs.Recheck do
  @moduledoc false
  # Two people may perform a verb on one record at the same moment, each
  # having read it before the other wrote. On Postgres the record is locked
  # for the transaction and `when` is asked again of the row as it stands
  # now, so the second one is refused instead of applying over the first.
  use Ash.Resource.Change
  require Ash.Query

  @postgres AshPostgres.DataLayer

  @impl true
  def change(changeset, _opts, context) do
    with %{} = verb <- verb(changeset),
         %{} = record when not is_nil(record.id) <- changeset.data,
         repo when not is_nil(repo) <- repo(changeset.resource) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["#{Mana.Entity.type(changeset.resource)}:#{record.id}"])

        holds? =
          changeset.resource
          |> Ash.Query.do_filter(Map.to_list(Map.take(record, Ash.Resource.Info.primary_key(changeset.resource))))
          |> Ash.Query.do_filter(Mana.Verbs.condition(verb.when, context.actor))
          |> Ash.exists?(authorize?: false)

        if holds?,
          do: changeset,
          else: Ash.Changeset.add_error(changeset, Mana.Verbs.unavailable(changeset.resource, verb))
      end)
    else
      _ -> changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp verb(changeset),
    do: Enum.find(Mana.Verbs.declared(changeset.resource), &(Mana.Verbs.action(&1) == changeset.action.name and not is_nil(&1.when) and not &1.idempotent and not &1.collection))

  defp repo(resource) do
    if Ash.DataLayer.data_layer(resource) == @postgres,
      do: apply(Module.concat(@postgres, Info), :repo, [resource, :mutate])
  end
end

defmodule Mana.Verbs.CollectionGate do
  @moduledoc false
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, context) do
    case Enum.find(Mana.Verbs.declared(changeset.resource), &(&1.collection and Mana.Verbs.action(&1) == changeset.action.name)) do
      nil ->
        :ok

      verb ->
        input = Map.merge(changeset.attributes, changeset.arguments)

        if not changeset.valid? or Mana.Verbs.collection_holds?(changeset.resource, verb, context.actor, input),
          do: :ok,
          else: {:error, Mana.Verbs.refusal(changeset.resource, verb, context.actor, input)}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end

defmodule Mana.Verbs.Validate do
  @moduledoc false
  # Runs after Ash's own transformers so default actions exist; an error here
  # stops compilation, unlike a verifier's.
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: true

  def transform(dsl) do
    module = Transformer.get_persisted(dsl, :module)
    verbs = Transformer.get_entities(dsl, [:verbs])
    actions = dsl |> Transformer.get_entities([:actions]) |> MapSet.new(& &1.name)
    names = MapSet.new(verbs, & &1.name)

    Enum.reduce_while(verbs, {:ok, dsl}, fn verb, ok ->
      cond do
        Mana.Verbs.action(verb) not in actions ->
          {:halt, error(module, verb, "has no action #{inspect(Mana.Verbs.action(verb))}")}

        verb.inverse && verb.inverse not in names ->
          {:halt, error(module, verb, "names an inverse #{inspect(verb.inverse)} that is not a declared verb")}

        verb.retry > 0 and not verb.idempotent ->
          {:halt, error(module, verb, "retries but is not idempotent; a resend could apply it twice")}

        verb.offline == :queue and not verb.idempotent ->
          {:halt, error(module, verb, "queues offline but is not idempotent; a replay could apply it twice")}

        verb.offline == :queue and verb.risk == :money ->
          {:halt, error(module, verb, "moves money and cannot wait in an offline queue")}

        verb.offline == :queue and verb.external ->
          {:halt, error(module, verb, "reaches #{verb.external} and cannot wait in an offline queue")}

        verb.from && not verb.collection ->
          {:halt, error(module, verb, "names a parent with from: but is not collection: true")}

        verb.collection && is_nil(verb.from) && not (is_nil(verb.when) or match?({m, f} when is_atom(m) and is_atom(f), verb.when)) ->
          {:halt, error(module, verb, "is record-less; its when is {Module, :fun}(actor)")}

        not verb.collection && match?({m, f} when is_atom(m) and is_atom(f), verb.when) ->
          {:halt, error(module, verb, "acts on its own record; its when is an expression the server can enforce")}

        true ->
          {:cont, ok}
      end
    end)
  end

  defp error(module, verb, message),
    do: {:error, Spark.Error.DslError.exception(module: module, path: [:verbs, verb.name], message: "verb #{inspect(verb.name)} #{message}")}
end
