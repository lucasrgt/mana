defmodule Mana.Reconcile.Desired do
  @moduledoc false
  defstruct [
    :name,
    :describe,
    :scope,
    :holds,
    :apply,
    :within,
    :since,
    :__identifier__,
    :__spark_metadata__
  ]
end

defmodule Mana.Reconcile do
  @moduledoc """
  Business rules as the state the world should be in, checked by a loop
  instead of trusted to every handler that might forget them:

      reconcile do
        desired :paid_has_charge, "every paid booking paid through the platform has a live charge",
          scope: expr(status == :paid and payment_mode == :intermediated),
          holds: {MyApp.Payments, :charged?}
      end

  `observe/2` streams the records in `scope` and asks `holds` about each:
  the rule has `converged` when every one holds, is `diverging` otherwise
  (with the records and details), and `blocked` when `apply` already tried
  and the record still diverges. `holds` is preferably an expression over
  the record (`holds: expr(not is_nil(charge_id))`): it is asked in the
  query, so only the diverging records are read. `{Module, :fun}`, called
  with each record in scope and answering `true`, `false` or
  `{false, detail}`, is for a rule an expression cannot say; it costs
  whatever the function reads, per record. With `apply`
  (`{Module, :fun}`), `observe(resource, apply: true)` asks it to bring each
  diverging record back, through verbs, and reports what stayed blocked.
  Without it the rule only observes — the first, safe step next to the
  handlers it may one day replace. `verdict/1` turns a report into an AVP
  verdict: converged passes, diverging fails with evidence.
  `Mana.Reconcile.Worker` runs `observe` on a schedule and emits
  `[:mana, :reconcile, :diverged]` telemetry.

  ## Rules with time

      desired :accepted_resolves, "an accepted booking is paid or expires within 15 minutes",
        scope: expr(status == :accepted),
        within: {15, :minute}

  `within` may be `{Module, :fun}`, called with the record and answering
  `{amount, unit}`, for a window that is a setting rather than code.
  A record diverges only once it has been in scope longer than `within`,
  measured from `since` (a timestamp field; `updated_at`, else
  `inserted_at`). Without `holds`, staying in scope that long is the
  divergence; with it, `holds` gets that long to become true.
  `observe(resource, now: datetime)` measures against another clock (or
  `now: fn record -> datetime end`, a clock per record, which is how
  `Mana.Explore` moves time).
  """

  @desired %Spark.Dsl.Entity{
    name: :desired,
    target: Mana.Reconcile.Desired,
    args: [:name, :describe],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      describe: [type: :string, required: true, doc: "The rule, as a person would say it."],
      scope: [
        type: :any,
        required: true,
        doc: "An expression selecting the records the rule is about."
      ],
      holds: [
        type: :any,
        doc:
          "An expression over the record, asked in the query; or `{Module, :fun}`: true, false or `{false, detail}` for a record. May be left out when `within` is given."
      ],
      within: [
        type:
          {:or,
           [
             {:tuple, [:pos_integer, {:in, [:second, :minute, :hour, :day]}]},
             {:tuple, [:atom, :atom]}
           ]},
        doc:
          "How long a record may stay in scope (or fail `holds`): `{15, :minute}`, or `{Module, :fun}` answering that for a record (a window read from a knob)."
      ],
      since: [type: :atom, doc: "The timestamp field `within` counts from."],
      apply: [
        type: {:tuple, [:atom, :atom]},
        doc: "`{Module, :fun}` that brings a diverging record back; observe-only without it."
      ]
    ]
  }

  @reconcile %Spark.Dsl.Section{name: :reconcile, imports: [Ash.Expr], entities: [@desired]}

  use Spark.Dsl.Extension, sections: [@reconcile], transformers: [Mana.Reconcile.Verify]

  require Ash.Expr
  alias Ash.Resource.Info
  alias Spark.Dsl.Extension

  def declared(resource), do: Extension.get_entities(resource, [:reconcile])

  @doc "Where each rule of `resource` stands; `apply: true` lets rules with `apply` repair."
  def observe(resource, opts \\ []) do
    for rule <- declared(resource), do: observe_rule(resource, rule, opts)
  end

  defp observe_rule(resource, rule, opts) do
    now = opts[:now] || DateTime.utc_now()
    {checked, diverging} = diverging(resource, rule, now)
    {repaired, blocked, remaining} = settle(resource, rule, diverging, opts[:apply])
    state = state(remaining, blocked)
    emit_diverged(resource, rule, state, remaining)

    %{
      rule: rule.name,
      describe: rule.describe,
      state: state,
      checked: checked,
      repaired: length(repaired),
      diverging: for({record, detail} <- remaining, do: %{id: record.id, detail: detail})
    }
  end

  # An expression `holds` is asked in the query: only the records failing it
  # are read (and, for a timed rule, those with no timestamp to count from,
  # which diverge whatever `holds` says), and the scope is only counted.
  defp diverging(resource, rule, now) do
    scope = Ash.Query.do_filter(resource, rule.scope)

    if expression?(rule.holds) do
      diverging =
        scope
        |> Ash.Query.do_filter(failing(rule, resource))
        |> stream()
        |> Enum.flat_map(&diverges(rule, &1, now, "does not hold"))

      {Ash.count!(scope, authorize?: false), diverging}
    else
      {checked, diverging} =
        scope
        |> stream()
        |> Enum.reduce({0, []}, fn record, {checked, diverging} ->
          {checked + 1, Enum.reverse(diverges(rule, record, now, holds(rule, record)), diverging)}
        end)

      {checked, Enum.reverse(diverging)}
    end
  end

  # A record fails `holds` when it is not true (false or unknown). Said as
  # `if`, which SQL writes as a parenthesized CASE: `is_nil(^holds)` would be
  # written `<holds> IS NULL` unparenthesized, which binds tighter than the
  # NOT or OR inside a negated or compound `holds`.
  defp failing(%{holds: holds, within: nil}, _resource),
    do: Ash.Expr.expr(type(if(^holds, do: false, else: true), :boolean))

  defp failing(%{holds: holds} = rule, resource) do
    since = since(rule, struct(resource))

    if Info.field(resource, since),
      do:
        Ash.Expr.expr(
          type(if(^holds, do: false, else: true), :boolean) or is_nil(^Ash.Expr.ref(since))
        ),
      else: true
  end

  defp diverges(rule, record, now, detail) do
    case divergence(rule, record, now, detail) do
      nil -> []
      detail -> [{record, detail}]
    end
  end

  # Ash streams by keyset pages when the primary read paginates (a default
  # `:read` does) and reads the scope at once otherwise.
  defp stream(query), do: Ash.stream!(query, authorize?: false, allow_stream_with: :full_read)

  defp settle(resource, rule, diverging, apply?) do
    if apply? && rule.apply do
      {repaired, blocked} =
        Enum.split_with(diverging, fn {record, _} -> repair(resource, rule, record) end)

      {repaired, blocked, blocked}
    else
      {[], [], diverging}
    end
  end

  defp state([], _blocked), do: :converged
  defp state(_remaining, []), do: :diverging
  defp state(_remaining, _blocked), do: :blocked

  defp emit_diverged(_resource, _rule, _state, []), do: :ok

  defp emit_diverged(resource, rule, state, remaining) do
    :telemetry.execute([:mana, :reconcile, :diverged], %{count: length(remaining)}, %{
      resource: resource,
      rule: rule.name,
      state: state
    })
  end

  # `detail` is why `holds` fails for the record, nil when it holds.
  defp divergence(%{within: nil}, _record, _now, detail), do: detail

  defp divergence(rule, record, now, detail) do
    case age(rule, record, now) do
      nil ->
        "has no #{since(rule, record)} to count #{duration(window(rule, record))} from"

      seconds ->
        overdue(rule, record, seconds, detail)
    end
  end

  defp overdue(rule, record, seconds, detail) do
    window = window(rule, record)

    if seconds > window and detail do
      "in scope for #{duration(seconds)}, longer than #{duration(window)}" <>
        if(rule.holds, do: ": #{detail}", else: "")
    end
  end

  # A timed rule without `holds` is about leaving the scope in time.
  defp holds(%{holds: nil}, _record), do: "still in scope"

  defp holds(%{holds: {module, function}}, record) when is_atom(module) and is_atom(function) do
    case apply(module, function, [record]) do
      true -> nil
      false -> "does not hold"
      {false, detail} -> detail
    end
  end

  defp holds(%{holds: holds}, record) do
    resource = record.__struct__

    held =
      case Ash.Expr.eval(holds,
             record: record,
             resource: resource,
             unknown_on_unknown_refs?: true
           ) do
        {:ok, value} ->
          value

        _ ->
          resource
          |> Ash.Query.do_filter(Map.to_list(Map.take(record, Info.primary_key(resource))))
          |> Ash.Query.do_filter(holds)
          |> Ash.exists?(authorize?: false)
      end

    if held == true, do: nil, else: "does not hold"
  end

  @doc false
  def expression?(nil), do: false
  def expression?({module, function}) when is_atom(module) and is_atom(function), do: false
  def expression?(_holds), do: true

  @doc false
  def window(%{within: {module, function}}, record) when is_atom(module) and is_atom(function),
    do: within_seconds(apply(module, function, [record]))

  def window(%{within: within}, _record), do: within_seconds(within)

  @doc false
  def within_seconds({amount, :second}), do: amount
  def within_seconds({amount, :minute}), do: amount * 60
  def within_seconds({amount, :hour}), do: amount * 3600
  def within_seconds({amount, :day}), do: amount * 86_400

  @doc false
  def since(%{since: field}, _record) when not is_nil(field), do: field

  def since(_rule, record),
    do: if(Map.has_key?(record, :updated_at), do: :updated_at, else: :inserted_at)

  defp age(rule, record, now) when is_function(now, 1), do: age(rule, record, now.(record))

  defp age(rule, record, now) do
    case Map.get(record, since(rule, record)) do
      %DateTime{} = at -> DateTime.diff(now, at, :second)
      %NaiveDateTime{} = at -> NaiveDateTime.diff(DateTime.to_naive(now), at, :second)
      _ -> nil
    end
  end

  # In its largest whole unit: "20d", not "1728003s".
  defp duration(seconds) when seconds >= 86_400, do: "#{div(seconds, 86_400)}d"
  defp duration(seconds) when seconds >= 3600, do: "#{div(seconds, 3600)}h"
  defp duration(seconds) when seconds >= 60, do: "#{div(seconds, 60)}m"
  defp duration(seconds), do: "#{seconds}s"

  # A repair refused by the domain (an Ash error answered or raised by the
  # verbs it performs) leaves the record blocked; anything else is a crash the
  # loop would hide, so it reaches the error reporter too. A repair that
  # removed the record settled it.
  defp repair(resource, rule, record) do
    {module, function} = rule.apply
    apply(module, function, [record])

    case Ash.read_one(primary_key(resource, record), authorize?: false) do
      {:ok, nil} ->
        true

      {:ok, fresh} ->
        not in_scope?(rule, fresh) or
          is_nil(divergence(rule, fresh, DateTime.utc_now(), holds(rule, fresh)))

      {:error, error} ->
        blocked(resource, rule, record, error)
    end
  rescue
    error -> blocked(resource, rule, record, Ash.Error.to_ash_error(error, __STACKTRACE__))
  end

  defp primary_key(resource, record),
    do:
      Ash.Query.do_filter(
        resource,
        Map.to_list(Map.take(record, Info.primary_key(resource)))
      )

  defp blocked(resource, rule, record, error) do
    case Ash.Error.to_error_class(error) do
      %class{} when class in [Ash.Error.Forbidden, Ash.Error.Invalid] ->
        false

      unknown ->
        report(%{resource: resource, rule: rule.name, id: record.id}, unknown)
        false
    end
  end

  require Logger

  # `config :mana_core, :error_reporter, {Mod, :fun}` (e.g. Sentry), called
  # with what the failure happened to and the error; the log without one.
  defp report(metadata, error) do
    case Application.get_env(:mana_core, :error_reporter) do
      {module, function} -> apply(module, function, [metadata, error])
      nil -> Logger.error("#{inspect(metadata)}: #{Exception.format(:error, error)}")
    end
  end

  # A repaired record may leave the rule's scope altogether (a lifted
  # suspension is no longer suspended); the rule is then no longer about it.
  defp in_scope?(rule, record),
    do:
      match?({:ok, true}, Ash.Expr.eval(rule.scope, record: record, resource: record.__struct__))

  @doc "An AVP verdict of a report: each rule a criterion, converged passing."
  def verdict(subject, report) do
    criteria =
      for rule <- report do
        %{
          "criterion" => to_string(rule.rule),
          "status" => if(rule.state == :converged, do: "pass", else: "fail"),
          "reason" =>
            if(rule.state == :converged,
              do: nil,
              else:
                "#{rule.describe}: #{length(rule.diverging)} of #{rule.checked} records diverge"
            ),
          "evidence" => Enum.map(rule.diverging, &%{"id" => &1.id, "detail" => &1.detail})
        }
      end

    passed = Enum.count(criteria, &(&1["status"] == "pass"))

    %{
      "subject" => subject,
      "outcome" => if(passed == length(criteria), do: "pass", else: "fail"),
      "acceptanceScore" => if(criteria == [], do: 1.0, else: passed / length(criteria)),
      "criteria" => criteria
    }
  end
end

defmodule Mana.Reconcile.Verify do
  @moduledoc false
  # A transformer, not a verifier, so the refusal is a compile error.
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def transform(dsl) do
    case Enum.find(
           Transformer.get_entities(dsl, [:reconcile]),
           &(is_nil(&1.holds) and is_nil(&1.within))
         ) do
      nil ->
        {:ok, dsl}

      rule ->
        {:error,
         DslError.exception(
           module: Transformer.get_persisted(dsl, :module),
           path: [:reconcile, rule.name],
           message: "desired #{inspect(rule.name)} needs holds:, within:, or both"
         )}
    end
  end
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Reconcile.Worker do
    @moduledoc """
    Observes the rules of every resource of an app's domains:
    `{"*/30 * * * *", Mana.Reconcile.Worker, args: %{otp_app: "my_app"}}`
    (add `"apply" => true` once rules repair on their own). With
    `config :mana_core, :reconcile_escalate, {Mod, :fun}` every rule's report
    of each run is handed over (resource, report), so what does not converge
    reaches a person and what converged again can be closed.
    """
    use Oban.Worker, queue: :maintenance, max_attempts: 1

    alias Ash.Domain.Info

    @impl true
    def perform(%Oban.Job{args: %{"otp_app" => otp_app} = args}) do
      escalate = Application.get_env(:mana_core, :reconcile_escalate)

      for domain <- otp_app |> String.to_existing_atom() |> Application.fetch_env!(:ash_domains),
          resource <- Info.resources(domain),
          Mana.Reconcile in Spark.extensions(resource),
          report <- Mana.Reconcile.observe(resource, apply: args["apply"] == true),
          {module, function} <- List.wrap(escalate),
          do: apply(module, function, [resource, report])

      :ok
    end
  end
end
