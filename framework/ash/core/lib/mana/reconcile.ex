defmodule Mana.Reconcile.Desired do
  @moduledoc false
  defstruct [:name, :describe, :scope, :holds, :apply, :__identifier__, :__spark_metadata__]
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

  `observe/2` reads the records in `scope` and asks `holds` (`{Module, :fun}`
  called with a record, answering `true`, `false` or `{false, detail}`)
  about each: the rule has `converged` when every one holds, is `diverging`
  otherwise (with the records and details), and `blocked` when `apply`
  already tried and the record still diverges. With `apply`
  (`{Module, :fun}`), `observe(resource, apply: true)` asks it to bring each
  diverging record back, through verbs, and reports what stayed blocked.
  Without it the rule only observes — the first, safe step next to the
  handlers it may one day replace. `verdict/1` turns a report into an AVP
  verdict: converged passes, diverging fails with evidence.
  `Mana.Reconcile.Worker` runs `observe` on a schedule and emits
  `[:mana, :reconcile, :diverged]` telemetry.
  """

  @desired %Spark.Dsl.Entity{
    name: :desired,
    target: Mana.Reconcile.Desired,
    args: [:name, :describe],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      describe: [type: :string, required: true, doc: "The rule, as a person would say it."],
      scope: [type: :any, required: true, doc: "An expression selecting the records the rule is about."],
      holds: [type: {:tuple, [:atom, :atom]}, required: true, doc: "`{Module, :fun}`: true, false or `{false, detail}` for a record."],
      apply: [type: {:tuple, [:atom, :atom]}, doc: "`{Module, :fun}` that brings a diverging record back; observe-only without it."]
    ]
  }

  @reconcile %Spark.Dsl.Section{name: :reconcile, imports: [Ash.Expr], entities: [@desired]}

  use Spark.Dsl.Extension, sections: [@reconcile]

  def declared(resource), do: Spark.Dsl.Extension.get_entities(resource, [:reconcile])

  @doc "Where each rule of `resource` stands; `apply: true` lets rules with `apply` repair."
  def observe(resource, opts \\ []) do
    for rule <- declared(resource) do
      records = resource |> Ash.Query.do_filter(rule.scope) |> Ash.read!(authorize?: false)
      diverging = for record <- records, detail = divergence(rule, record), do: {record, detail}

      {repaired, blocked} =
        if opts[:apply] && rule.apply,
          do: Enum.split_with(diverging, fn {record, _} -> repair(rule, record) end),
          else: {[], []}

      remaining = if opts[:apply] && rule.apply, do: blocked, else: diverging

      state =
        cond do
          remaining == [] -> :converged
          blocked != [] -> :blocked
          true -> :diverging
        end

      if remaining != [] do
        :telemetry.execute([:mana, :reconcile, :diverged], %{count: length(remaining)}, %{resource: resource, rule: rule.name, state: state})
      end

      %{
        rule: rule.name,
        describe: rule.describe,
        state: state,
        checked: length(records),
        repaired: length(repaired),
        diverging: for({record, detail} <- remaining, do: %{id: record.id, detail: detail})
      }
    end
  end

  defp divergence(rule, record) do
    {module, function} = rule.holds

    case apply(module, function, [record]) do
      true -> nil
      false -> "does not hold"
      {false, detail} -> detail
    end
  end

  defp repair(rule, record) do
    {module, function} = rule.apply
    apply(module, function, [record])
    {:ok, fresh} = Ash.get(record.__struct__, record.id, authorize?: false)
    not in_scope?(rule, fresh) or is_nil(divergence(rule, fresh))
  rescue
    _ -> false
  end

  # A repaired record may leave the rule's scope altogether (a lifted
  # suspension is no longer suspended); the rule is then no longer about it.
  defp in_scope?(rule, record), do: match?({:ok, true}, Ash.Expr.eval(rule.scope, record: record, resource: record.__struct__))

  @doc "An AVP verdict of a report: each rule a criterion, converged passing."
  def verdict(subject, report) do
    criteria =
      for rule <- report do
        %{
          "criterion" => to_string(rule.rule),
          "status" => if(rule.state == :converged, do: "pass", else: "fail"),
          "reason" => if(rule.state == :converged, do: nil, else: "#{rule.describe}: #{length(rule.diverging)} of #{rule.checked} records diverge"),
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

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Reconcile.Worker do
    @moduledoc """
    Observes the rules of every resource of an app's domains:
    `{"*/30 * * * *", Mana.Reconcile.Worker, args: %{otp_app: "my_app"}}`
    (add `"apply" => true` once rules repair on their own).
    """
    use Oban.Worker, queue: :maintenance, max_attempts: 1

    @impl true
    def perform(%Oban.Job{args: %{"otp_app" => otp_app} = args}) do
      for domain <- otp_app |> String.to_existing_atom() |> Application.fetch_env!(:ash_domains),
          resource <- Ash.Domain.Info.resources(domain),
          Mana.Reconcile in Spark.extensions(resource),
          do: Mana.Reconcile.observe(resource, apply: args["apply"] == true)

      :ok
    end
  end
end
