defmodule Mana.Flow.Step do
  @moduledoc false
  defstruct [:name, :action, :skip_if, :optional, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Flow do
  @moduledoc """
  A journey of several steps kept on the record itself, so it resumes on any
  device where it stopped and the server alone decides what comes next:

      flow do
        cursor :lifecycle_state
        before [:review_demo]
        step :terms_pending, action: :advance_terms
        step :details_pending, action: :save_details
        step :address_pending, action: :save_address, skip_if: expr(kind == :virtual)
        done :complete
        stuck_after {3, :day}
        on_stuck {MyApp.Reminders, :host_stuck}
        not_reached {MyApp.Hosts, :error, [:previous_step_incomplete]}
      end

  Each step's `action` may run once the cursor reached that step: finishing
  the current step moves the cursor to the next one (past any whose
  `skip_if` holds for the record), revisiting an earlier step never moves it
  back, and a step not reached yet is refused with `not_reached` (an MFA
  returning the error; `flow.step_not_reached` by default). States in
  `before` sit outside the flow and never advance.

  Records get a public `flow` calculation (`step`, `index`, `total`,
  `progress`, `done`) for interfaces. When a step is entered and
  `stuck_after` is set, a durable job checks later whether the cursor is
  still there; if so it diagnoses why (`diagnose/2`: a bug or an
  abandonment, from the record's `Mana.History`) and calls `on_stuck` —
  remind the abandoned, alert on the bug. `funnel/1` counts records per
  step. The contract carries `x-mana-flow`; the client gets
  `<Type>Flow.flow`.
  """

  @step %Spark.Dsl.Entity{
    name: :step,
    target: Mana.Flow.Step,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true, doc: "The cursor value while this step is the current one."],
      action: [type: :atom, required: true, doc: "The update action that completes the step."],
      skip_if: [type: :any, doc: "An expression over the record; the step is passed over while it holds."],
      optional: [type: :boolean, default: false, doc: "Interfaces may offer to skip it."]
    ]
  }

  @flow %Spark.Dsl.Section{
    name: :flow,
    imports: [Ash.Expr],
    entities: [@step],
    schema: [
      cursor: [type: :atom, required: true, doc: "The attribute holding the current step."],
      done: [type: :atom, required: true, doc: "The cursor value once every step is complete."],
      before: [type: {:list, :atom}, default: [], doc: "Cursor values outside the flow that never advance."],
      stuck_after: [type: :any, doc: "`{amount, unit}` after entering a step to check whether it moved, or `{Module, :function}` answering it when the step is entered (a knob)."],
      on_stuck: [type: {:tuple, [:atom, :atom]}, doc: "`{Module, :function}` called with the record and the step still current."],
      not_reached: [type: :mfa, doc: "`{Module, :function, args}` returning the error for a step not reached."],
      queue: [type: :atom, default: :default, doc: "The Oban queue of stuck checks."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@flow], transformers: [Mana.Flow.Transformer]
  use Mana.Primitive, contract: "x-mana-flow", catalog: "flows", moments: [:observe]

  def steps(resource), do: Spark.Dsl.Extension.get_entities(resource, [:flow])
  defp opt(resource, key, default \\ nil), do: Spark.Dsl.Extension.get_opt(resource, [:flow], key, default)

  def cursor(resource), do: opt(resource, :cursor)
  def done(resource), do: opt(resource, :done)

  @doc "The step names in order, then the done value."
  def order(resource), do: Enum.map(steps(resource), & &1.name) ++ [done(resource)]

  @doc "Where `record` stands: its step, position and progress."
  def position(record) do
    resource = record.__struct__
    order = order(resource)
    current = Map.get(record, cursor(resource))
    total = length(order) - 1
    index = Enum.find_index(order, &(&1 == current))

    %{
      step: to_string(current),
      index: index || 0,
      total: total,
      progress: if(index, do: Float.round(index / max(total, 1), 2), else: 0.0),
      done: current == done(resource)
    }
  end

  @doc "How many records stand at each step (and done), in order."
  def funnel(resource, opts \\ []) do
    require Ash.Query
    field = cursor(resource)

    for value <- order(resource) do
      count = resource |> Ash.Query.filter(^Ash.Expr.ref(field) == ^value) |> Ash.count!(Keyword.put_new(opts, :authorize?, false))
      {value, count}
    end
  end

  @impl Mana.Primitive
  def contract(resource) do
    [
      %{
        "cursor" => to_string(cursor(resource)),
        "done" => to_string(done(resource)),
        "steps" =>
          for step <- steps(resource) do
            %{"name" => to_string(step.name), "action" => to_string(step.action), "optional" => step.optional, "skippable" => not is_nil(step.skip_if)}
          end
      }
    ]
  end

  @doc "Whether `action` may run on `record` now: not a step, or a step the cursor reached."
  def may_run?(record, action) do
    resource = record.__struct__

    case Enum.find(steps(resource), &(&1.action == action)) do
      nil ->
        true

      step ->
        current = Map.get(record, cursor(resource))
        current not in opt(resource, :before, []) and reached?(order(resource), current, step.name)
    end
  end

  @doc false
  def advance(changeset) do
    resource = changeset.resource
    steps = steps(resource)

    case Enum.find(steps, &(&1.action == changeset.action.name)) do
      nil ->
        changeset

      step ->
        field = cursor(resource)
        current = Map.get(changeset.data, field)
        order = order(resource)

        cond do
          current in opt(resource, :before, []) or not reached?(order, current, step.name) ->
            Ash.Changeset.add_error(changeset, not_reached(resource))

          current == step.name ->
            changeset
            |> Ash.Changeset.force_change_attribute(field, next(resource, step.name, changeset))
            |> Ash.Changeset.after_action(fn _changeset, record ->
              schedule(record)
              {:ok, record}
            end)

          true ->
            changeset
        end
    end
  end

  defp reached?(order, current, step) do
    with at when is_integer(at) <- Enum.find_index(order, &(&1 == current)),
         wanted when is_integer(wanted) <- Enum.find_index(order, &(&1 == step)) do
      at >= wanted
    else
      _ -> false
    end
  end

  defp next(resource, name, changeset) do
    record = struct(changeset.data, changeset.attributes)

    resource
    |> steps()
    |> Enum.drop_while(&(&1.name != name))
    |> Enum.drop(1)
    |> Enum.find(&(not skipped?(&1, record)))
    |> case do
      nil -> done(resource)
      step -> step.name
    end
  end

  defp skipped?(%{skip_if: nil}, _record), do: false
  defp skipped?(%{skip_if: expression}, record), do: match?({:ok, true}, Ash.Expr.eval(expression, record: record, resource: record.__struct__))

  defp not_reached(resource) do
    case opt(resource, :not_reached) do
      {module, function, args} -> apply(module, function, args)
      nil -> Mana.Error.new("flow.step_not_reached", "complete the previous step first", status: 422)
    end
  end

  defp stuck_after({amount, unit}) when is_integer(amount), do: {amount, unit}
  defp stuck_after({module, function}) when is_atom(module) and is_atom(function), do: apply(module, function, [])
  defp stuck_after(_), do: nil

  @doc false
  def schedule(record) do
    resource = record.__struct__
    current = Map.get(record, cursor(resource))

    with {amount, unit} <- stuck_after(opt(resource, :stuck_after)),
         true <- current != done(resource) do
      inserter = Application.get_env(:mana_core, :deadline_inserter, &insert/1)
      args = %{"resource" => inspect(resource), "id" => record.id, "step" => to_string(current), "kind" => "flow_stuck"}
      inserter.(%{args: args, queue: opt(resource, :queue, :default), scheduled_at: DateTime.add(DateTime.utc_now(), amount, unit)})
    end

    :ok
  end

  defp insert(%{args: args, queue: queue, scheduled_at: at}),
    do: args |> Mana.Flow.Worker.new(queue: queue, scheduled_at: at) |> Oban.insert!()

  @doc """
  When `record` still sits at `step`, diagnoses why (`diagnose/2`), emits
  `[:mana, :flow, :stuck]` telemetry with the diagnosis and calls `on_stuck`
  with the record, the step and the diagnosis (or just the first two when it
  takes two). Does nothing when the record moved on.
  """
  def check_stuck(resource, id, step) do
    with {:ok, record} <- Ash.get(resource, id, authorize?: false),
         true <- to_string(Map.get(record, cursor(resource))) == step do
      step = String.to_existing_atom(step)
      diagnosis = diagnose(record, step)
      :telemetry.execute([:mana, :flow, :stuck], %{attempts: diagnosis.attempts}, %{resource: resource, id: id, step: step, verdict: diagnosis.verdict})

      case opt(resource, :on_stuck) do
        {module, function} ->
          if function_exported?(module, function, 3),
            do: apply(module, function, [record, step, diagnosis]),
            else: apply(module, function, [record, step])

        nil ->
          :ok
      end

      diagnosis.verdict
    else
      _ -> :moved
    end
  end

  @technical ~w(unknown framework exception error)

  @doc """
  Why `record` sits at `step`, from its `Mana.History` (when it keeps one):
  `:bug` when an attempt at the step's action failed for a technical reason
  (an unknown or framework error, not a refused input), `:abandoned`
  otherwise — no attempt at all, or only refused inputs and then silence.
  Interfaces answer the first with an alert, the second with a reminder.
  """
  def diagnose(record, step) do
    resource = record.__struct__
    action = Enum.find_value(steps(resource), &(&1.name == step && to_string(&1.action)))

    entries =
      if Mana.History in Spark.extensions(resource) do
        resource
        |> Mana.History.log()
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter_input(%{subject_type: Mana.Entity.type(resource), subject_id: to_string(record.id), action: action})
        |> Ash.read!(authorize?: false)
      else
        []
      end

    failures = for entry <- entries, entry.outcome == :failed, do: entry.error
    technical = Enum.filter(failures, &(&1 in @technical))

    %{
      step: step,
      verdict: if(technical != [], do: :bug, else: :abandoned),
      attempts: length(entries),
      failures: failures
    }
  end
end

defmodule Mana.Flow.Advance do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context), do: Mana.Flow.advance(changeset)
end

defmodule Mana.Flow.Position do
  @moduledoc false
  use Ash.Resource.Calculation

  @impl true
  def load(query, _opts, _context), do: [Mana.Flow.cursor(query.resource)]

  @impl true
  def calculate(records, _opts, _context), do: Enum.map(records, &Mana.Flow.position/1)
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Flow.Worker do
    @moduledoc false
    use Oban.Worker, max_attempts: 3

    @impl true
    def perform(%Oban.Job{args: %{"resource" => resource, "id" => id, "step" => step}}) do
      resource |> String.trim_leading("Elixir.") |> String.split(".") |> Module.safe_concat() |> Mana.Flow.check_stuck(id, step)
      :ok
    end
  end
end

defmodule Mana.Flow.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:flow]) do
      [] ->
        {:ok, dsl}

      _ ->
        position = [
          step: [type: :string, allow_nil?: false],
          index: [type: :integer, allow_nil?: false],
          total: [type: :integer, allow_nil?: false],
          progress: [type: :float, allow_nil?: false],
          done: [type: :boolean, allow_nil?: false]
        ]

        with {:ok, dsl} <- Ash.Resource.Builder.add_change(dsl, Mana.Flow.Advance, on: [:update]) do
          Ash.Resource.Builder.add_new_calculation(dsl, :flow, :map, Mana.Flow.Position,
            public?: true,
            constraints: [fields: position],
            description: "Where the record stands in its flow."
          )
        end
    end
  end
end
