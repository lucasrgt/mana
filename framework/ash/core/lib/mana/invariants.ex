defmodule Mana.Invariants.Invariant do
  @moduledoc false
  defstruct [:name, :describe, :scope, :holds, :because, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Invariants do
  @moduledoc """
  The laws of a resource: what must hold for every record after every
  action, whichever action it is and whoever wrote it:

      invariants do
        invariant :refund_within_paid, "a refund never exceeds what was paid",
          holds: expr(refunded_cents <= amount_cents)

        invariant :paid_has_money, "a booking paid through the platform has its money held or captured",
          scope: expr(status == :paid and payment_mode == :intermediated),
          holds: {MyApp.Payments, :charged?}
      end

  A record in `scope` (every record without one) for which `holds` is false
  is refused with the domain error `invariant.<name>` (status 409) and
  `[:mana, :invariant, :refused]` telemetry. `holds` is an expression over
  the record, or `{Module, :fun}` called with the record, answering `true`,
  `false` or `{false, detail}` — the shape of a `Mana.Reconcile` rule: a
  rule that must never be broken belongs here, one that becomes true over
  time (a deadline, an answer from outside) stays there.

  Boundary (guaranteed): every create and update action of the resource.
  A non-atomic write is checked before it is written, as every other change
  left it, on any data layer; `{Module, :fun}` laws see it the same way. An
  atomic write (the Ash default for updates), and an expression that reaches
  other rows (`exists(charges, ...)`), are checked right after the write,
  inside the action's transaction, so the refusal rolls the write back — on
  a data layer with transactions. Outside the boundary: `Ash.Seed`, bulk
  writes that skip changes, direct SQL, and a change to *another* resource
  that a `{Module, :fun}` law reads (declare the law on that resource too).
  `violations/1` finds what got in that way, and `verdict/2` judges it.

  A law is checked when its action writes, not when the transaction
  commits: a law over other rows (`exists(charges, ...)`, a `{Module, :fun}`
  reading them) sees the half-done state of a transaction that changes both
  sides in turn. Such a rule is a `Mana.Reconcile` rule, explored with
  `Mana.Explore` `eventual:`; a law here is about what the record itself says.
  """

  @invariant %Spark.Dsl.Entity{
    name: :invariant,
    target: Mana.Invariants.Invariant,
    args: [:name, :describe],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      describe: [type: :string, required: true, doc: "The law, as a person would say it."],
      scope: [type: :any, doc: "An expression selecting the records the law is about; every record without it."],
      holds: [type: :any, required: true, doc: "An expression over the record, or `{Module, :fun}`: true, false or `{false, detail}` for a record."],
      because: [type: :string, doc: "The notebook note (`mana note`) that decided this law."]
    ]
  }

  @invariants %Spark.Dsl.Section{name: :invariants, imports: [Ash.Expr], entities: [@invariant]}

  use Spark.Dsl.Extension, sections: [@invariants], transformers: [Mana.Invariants.Transformer]

  def declared(resource), do: Spark.Dsl.Extension.get_entities(resource, [:invariants])

  @doc """
  The laws `record` breaks, as `{invariant, detail}`. `phase` is `:stored`
  (the record is written: anything may be asked of its row), `:unwritten`
  (only what the record itself answers; the rest is left for `:written`) or
  `:written` (only what `:unwritten` left).
  """
  def broken(record, phase \\ :stored) do
    for law <- declared(record.__struct__), detail = judge(law, record, phase), detail != :ok, do: {law, detail}
  end

  @doc "The domain error a broken law answers."
  def error(%Mana.Invariants.Invariant{} = law, detail) do
    Mana.Error.new("invariant.#{law.name}", law.describe, status: 409, meta: %{invariant: law.name, detail: detail})
  end

  @doc "Every record of `resource` that breaks a law now, by law."
  def violations(resource) do
    records = Ash.read!(resource, authorize?: false)

    for law <- declared(resource) do
      breaking = for record <- records, detail = judge(law, record, :stored), detail != :ok, do: %{id: record.id, detail: detail}
      %{invariant: law.name, describe: law.describe, checked: length(records), breaking: breaking}
    end
  end

  @doc "An AVP verdict of `violations/1`: each law a criterion, passing when no record breaks it."
  def verdict(subject, report) do
    criteria =
      for law <- report do
        %{
          "criterion" => to_string(law.invariant),
          "status" => if(law.breaking == [], do: "pass", else: "fail"),
          "reason" => if(law.breaking == [], do: nil, else: "#{law.describe}: #{length(law.breaking)} of #{law.checked} records break it"),
          "evidence" => Enum.map(law.breaking, &%{"id" => &1.id, "detail" => &1.detail})
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

  # :ok, or the detail of the breach. A record not yet written is asked only
  # what it answers in memory (its stored row is still the old one); a law
  # it cannot answer is left for the written phase.
  defp judge(law, record, :stored), do: settle(law, record)

  defp judge(law, record, :unwritten) do
    if memory(law.scope, record) == true do
      case law.holds do
        {module, function} -> called(apply(module, function, [record]))
        expression -> if memory(expression, record) == false, do: "does not hold", else: :ok
      end
    else
      :ok
    end
  end

  defp judge(law, record, :written), do: if(answered_unwritten?(law, record), do: :ok, else: settle(law, record))

  defp answered_unwritten?(law, record) do
    case memory(law.scope, record) do
      false -> true
      :unknown -> false
      true -> match?({_, _}, law.holds) or memory(law.holds, record) != :unknown
    end
  end

  defp settle(law, record) do
    if stored(law.scope, record) do
      case law.holds do
        {module, function} -> called(apply(module, function, [record]))
        expression -> if stored(expression, record), do: :ok, else: "does not hold"
      end
    else
      :ok
    end
  end

  defp called(true), do: :ok
  defp called(false), do: "does not hold"
  defp called({false, detail}), do: detail

  defp memory(nil, _record), do: true

  defp memory(expression, record) do
    case Ash.Expr.eval(expression, record: record, resource: record.__struct__, unknown_on_unknown_refs?: true) do
      {:ok, value} when is_boolean(value) or is_nil(value) -> value == true
      _ -> :unknown
    end
  end

  defp stored(expression, record) do
    case memory(expression, record) do
      :unknown ->
        resource = record.__struct__
        keys = Map.take(record, Ash.Resource.Info.primary_key(resource)) |> Map.to_list()
        resource |> Ash.Query.do_filter(keys) |> Ash.Query.do_filter(expression) |> Ash.exists?(authorize?: false)

      known ->
        known
    end
  end
end

defmodule Mana.Invariants.Check do
  @moduledoc false
  # Its hook is registered after every action change's, so the record it
  # checks is the one the other changes finished shaping. Ash skips
  # before_action hooks on an atomic write, so that path is checked written.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&refuse_unwritten/1)
    |> Ash.Changeset.after_action(&refuse_written(&1, &2, :written))
  end

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, Ash.Changeset.after_action(changeset, &refuse_written(&1, &2, :stored))}

  defp refuse_unwritten(changeset) do
    {:ok, record} = Ash.Changeset.apply_attributes(changeset, force?: true)

    case Mana.Invariants.broken(record, :unwritten) do
      [] -> changeset
      [{law, detail} | _] -> Ash.Changeset.add_error(changeset, refused(changeset, law, detail))
    end
  end

  defp refuse_written(changeset, record, phase) do
    case Mana.Invariants.broken(record, phase) do
      [] -> {:ok, record}
      [{law, detail} | _] -> {:error, refused(changeset, law, detail)}
    end
  end

  defp refused(changeset, law, detail) do
    :telemetry.execute([:mana, :invariant, :refused], %{count: 1}, %{resource: changeset.resource, action: changeset.action.name, invariant: law.name, detail: detail})
    Mana.Invariants.error(law, detail)
  end
end

defmodule Mana.Invariants.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def before?(_), do: false
  def after?(_), do: true

  def transform(dsl) do
    if Transformer.get_entities(dsl, [:invariants]) == [],
      do: {:ok, dsl},
      else: Ash.Resource.Builder.add_change(dsl, Mana.Invariants.Check, on: [:create, :update])
  end
end
