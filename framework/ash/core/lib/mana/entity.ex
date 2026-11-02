defmodule Mana.Entity.Deadline do
  @moduledoc false
  defstruct [:name, :action, :when, :after, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Entity do
  @moduledoc """
  A resource whose records are live: every change is announced to whoever
  watches it, and its deadlines live with it instead of in a cron that scans
  the table.

      entity do
        broadcast MyAppWeb.Endpoint
        audience [:traveler_id, :host_id]
        deadline :expire, action: :expire_unpaid, when: expr(status == :accepted), after: {15, :minute}
      end

  Once each create, update or destroy has committed, the record's topic
  `entity:<type>:<id>`, and `entity:<type>:for:<user>` for each `audience`
  field, receive `"changed"` with only the id: clients read the record again
  through the API, with their own authorization, so a subscriber never sees
  data its policies would hide. The announcement comes from an Ash notifier,
  so a change that rolls back is never announced, and one nested in a larger
  transaction (`Ash.transact/3`) is announced when that one commits. Bulk
  actions announce only with `notify?: true`, as for every Ash notifier.
  `Mana.Entity.Channel` joins those topics after checking the reader may read
  the record (or is the audience user).

  A deadline is a durable Oban job inserted in the transaction of the change
  that leaves the record satisfying `when` (a change that rolls back
  schedules nothing), one per record and deadline while it waits: later
  changes that keep `when` true do not move or repeat it. When it runs, its
  update asks `when` again of the stored row once it holds the record's
  lock, and a record that moved on (paid meanwhile) is left alone. It
  survives deploys and multiple nodes; it is not an in-memory timer. `after`
  is `{amount, unit}` or `{Module, :function}` returning the `DateTime` for
  a record.

  On AshPostgres, every update and destroy of a resource with deadlines
  takes the record's transaction lock (`Mana.Lock`, the key `Mana.Verbs`
  rechecks under), so a deadline and a payment run one after the other and
  the later one finds the record as the earlier left it. The lock is a
  `before_action` hook, which Ash cannot run in an atomic update, so exactly
  those actions get `require_atomic?: false`; without deadlines, or on
  another data layer, no lock is taken and actions stay atomic. Writes that
  skip the actions (`Ash.Seed`, SQL) skip the lock and the announcement.
  """
  # Optional dependencies, called only when the app has them.
  @compile {:no_warn_undefined,
            [AshJsonApi.Resource.Info, AshPostgres.DataLayer.Info, Mana.Entity.Worker, Oban]}
  @postgres AshPostgres.DataLayer

  alias Mana.Entity.Worker
  alias Spark.Dsl.Extension

  @deadline %Spark.Dsl.Entity{
    name: :deadline,
    target: Mana.Entity.Deadline,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      action: [
        type: :atom,
        required: true,
        doc: "The update action performed when the deadline passes."
      ],
      when: [
        type: :any,
        required: true,
        doc: "The state the deadline watches; it fires only while this holds."
      ],
      after: [
        type: :any,
        required: true,
        doc: "`{amount, unit}` from the change, or `{Module, :function}` → DateTime."
      ]
    ]
  }

  @entity %Spark.Dsl.Section{
    name: :entity,
    imports: [Ash.Expr],
    entities: [@deadline],
    schema: [
      type: [
        type: :string,
        doc: "The topic name; the JSON:API type or the module's last segment by default."
      ],
      broadcast: [type: :atom, doc: "A module with `broadcast/3` (a Phoenix endpoint)."],
      audience: [
        type: {:list, :atom},
        default: [],
        doc: "User-id fields whose user follows every change."
      ],
      watchers: [
        type: {:tuple, [:atom, :atom]},
        doc:
          "`{Module, :fun}`(user) → true for who may follow every record of the type on `entity:<type>:all` (an operator's queue)."
      ],
      queue: [type: :atom, default: :default, doc: "The Oban queue deadlines run on."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@entity], transformers: [Mana.Entity.Transformer]
  use Mana.Primitive, contract: "x-mana-entity", catalog: "entities", moments: [:observe, :fake]

  @doc "Moments `observe`: the topics `record` is announced on and the deadlines whose condition holds now."
  def observe(record) do
    %{
      "topics" => topics(record),
      "deadlines" =>
        for(
          deadline <- deadlines(record.__struct__),
          holds?(deadline.when, record),
          do: to_string(deadline.name)
        )
    }
  end

  @doc "Moments `fake`: deadline `name` of the record comes due now, as if its time had passed."
  def fake(resource, id, name), do: run_deadline(resource, id, to_string(name))

  @impl Mana.Primitive
  def contract(resource) do
    [
      %{
        "topic" => type(resource),
        "audience" => Enum.map(audience(resource), &to_string/1),
        "deadlines" => Enum.map(deadlines(resource), &to_string(&1.name))
      }
      |> then(&if watchers(resource), do: Map.put(&1, "watchable", true), else: &1)
    ]
  end

  def deadlines(resource), do: Extension.get_entities(resource, [:entity])

  @doc "Every live resource of `otp_app`'s domains."
  def resources(otp_app) do
    for domain <- Application.get_env(otp_app, :ash_domains, []),
        resource <- Ash.Domain.Info.resources(domain),
        __MODULE__ in Spark.extensions(resource),
        do: resource
  end

  def audience(resource), do: Extension.get_opt(resource, [:entity], :audience, [])
  def watchers(resource), do: Extension.get_opt(resource, [:entity], :watchers, nil)
  def broadcaster(resource), do: Extension.get_opt(resource, [:entity], :broadcast, nil)
  def queue(resource), do: Extension.get_opt(resource, [:entity], :queue, :default)

  def type(resource) do
    Extension.get_opt(resource, [:entity], :type, nil) ||
      (Code.ensure_loaded?(AshJsonApi.Resource.Info) &&
         AshJsonApi.Resource in Spark.extensions(resource) &&
         to_string(AshJsonApi.Resource.Info.type(resource))) ||
      resource |> Module.split() |> List.last() |> Macro.underscore()
  end

  @doc "The topics a change to `record` is announced on."
  def topics(record) do
    resource = record.__struct__
    type = type(resource)

    [
      "entity:#{type}:#{record.id}"
      | for(
          field <- audience(resource),
          user = Map.get(record, field),
          do: "entity:#{type}:for:#{user}"
        )
    ] ++
      if(watchers(resource), do: ["entity:#{type}:all"], else: [])
  end

  @doc false
  def announce(record) do
    if broadcaster = broadcaster(record.__struct__) do
      for topic <- topics(record),
          do:
            broadcaster.broadcast(topic, "changed", %{
              "id" => record.id,
              "type" => type(record.__struct__)
            })
    end

    :ok
  end

  @doc false
  def holds?(expression, record) do
    resource = record.__struct__

    if Ash.DataLayer.data_layer_can?(resource, :filter) and
         Ash.Resource.Info.primary_key(resource) != [] do
      # Asked of the stored row, so the expression may reach relationships
      # (`exists(charges, ...)`) that the record in hand has not loaded.
      resource
      |> Ash.Query.do_filter(
        Map.to_list(Map.take(record, Ash.Resource.Info.primary_key(resource)))
      )
      |> Ash.Query.do_filter(expression)
      |> Ash.exists?(authorize?: false)
    else
      match?({:ok, true}, Ash.Expr.eval(expression, record: record, resource: resource))
    end
  end

  @doc false
  def due_at(%{after: {amount, unit}}, _record) when is_integer(amount),
    do: DateTime.add(DateTime.utc_now(), amount, unit)

  def due_at(%{after: {module, function}}, record), do: apply(module, function, [record])

  @doc false
  def schedule(record) do
    resource = record.__struct__

    for deadline <- deadlines(resource), holds?(deadline.when, record) do
      inserter = Application.get_env(:mana_core, :deadline_inserter, &insert/1)

      args = %{
        "resource" => inspect(resource),
        "id" => record.id,
        "deadline" => to_string(deadline.name)
      }

      inserter.(%{args: args, queue: queue(resource), scheduled_at: due_at(deadline, record)})
    end

    :ok
  end

  defp insert(%{args: args, queue: queue, scheduled_at: at}),
    do: args |> Worker.new(queue: queue, scheduled_at: at) |> Oban.insert!()

  @moved_on "deadline.moved_on"

  @doc """
  Runs a passed deadline when its record still satisfies it; otherwise does
  nothing. `when` is asked once more inside the update, under the record's
  lock, so a change that committed meanwhile wins.
  """
  def run_deadline(resource, id, name) do
    with %{} = deadline <- Enum.find(deadlines(resource), &(to_string(&1.name) == name)),
         {:ok, record} <- Ash.get(resource, id, authorize?: false),
         true <- holds?(deadline.when, record) do
      record
      |> Ash.Changeset.for_update(deadline.action, %{},
        authorize?: false,
        context: %{mana_deadline: deadline.name}
      )
      |> recheck(deadline)
      |> Ash.update()
      |> ran()
    else
      _ -> :ok
    end
  end

  defp ran({:ok, _}), do: :ok

  defp ran({:error, error}),
    do: if(moved_on?(error), do: :ok, else: raise(Ash.Error.to_error_class(error)))

  # Without the lock (no deadlines, or not Postgres) the action stays atomic,
  # and a before_action hook would stop that.
  defp recheck(changeset, deadline) do
    if lock_repo(changeset.resource),
      do: Ash.Changeset.before_action(changeset, &still_due(&1, deadline)),
      else: changeset
  end

  # Runs after Mana.Entity.Changed's lock, which `for_update` added first.
  defp still_due(changeset, deadline) do
    if holds?(deadline.when, changeset.data),
      do: changeset,
      else:
        Ash.Changeset.add_error(
          changeset,
          Mana.Error.new(@moved_on, "the record no longer satisfies the deadline", status: 409)
        )
  end

  @doc false
  # A deadline that found its record moved on changed nothing and failed no one.
  def moved_on?(error) do
    error
    |> Ash.Error.to_error_class()
    |> Map.get(:errors, [])
    |> Enum.any?(&match?(%Mana.Error{code: @moved_on}, &1))
  end

  @doc false
  def lock_key(resource, id), do: "#{type(resource)}:#{id}"

  @doc false
  # The repo whose transaction lock the changes of `resource`'s records take,
  # nil when they take none.
  def lock_repo(resource) do
    if Ash.DataLayer.data_layer(resource) == @postgres and deadlines(resource) != [],
      do: AshPostgres.DataLayer.Info.repo(resource, :mutate)
  end
end

defmodule Mana.Entity.Changed do
  @moduledoc false
  # Added only to resources with deadlines: their jobs are inserted with the
  # change, in its transaction, and on Postgres the record is locked first.
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> one_at_a_time()
    |> Ash.Changeset.after_action(fn _changeset, record ->
      Mana.Entity.schedule(record)
      {:ok, record}
    end)
  end

  defp one_at_a_time(%{action_type: type, data: %{id: id}, resource: resource} = changeset)
       when type in [:update, :destroy] and not is_nil(id) do
    case Mana.Entity.lock_repo(resource) do
      nil ->
        changeset

      repo ->
        Ash.Changeset.before_action(changeset, fn changeset ->
          Mana.Lock.record(repo, Mana.Entity.lock_key(resource, id))
          changeset
        end)
    end
  end

  defp one_at_a_time(changeset), do: changeset

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end

defmodule Mana.Entity.Notifier do
  @moduledoc false
  # An Ash notifier runs once the outermost transaction commits and never for
  # one that rolls back, so "changed" never sends a client to read a write
  # that is not there.
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{data: %{} = record}), do: Mana.Entity.announce(record)
  def notify(_notification), do: :ok
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Entity.Worker do
    @moduledoc false
    # One job per record and deadline while it waits: every change that keeps
    # `when` true schedules again, and only the first stands.
    use Oban.Worker,
      max_attempts: 3,
      unique: [
        period: :infinity,
        keys: [:resource, :id, :deadline],
        states: [:available, :scheduled, :retryable]
      ]

    @impl true
    def perform(%Oban.Job{args: %{"resource" => resource, "id" => id, "deadline" => name}}) do
      resource
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.safe_concat()
      |> Mana.Entity.run_deadline(id, name)
    end
  end
end

defmodule Mana.Entity.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(_), do: true

  def transform(dsl) do
    dsl =
      if Transformer.get_option(dsl, [:entity], :broadcast),
        do:
          Transformer.persist(
            dsl,
            :simple_notifiers,
            Enum.uniq(
              Transformer.get_persisted(dsl, :simple_notifiers, []) ++ [Mana.Entity.Notifier]
            )
          ),
        else: dsl

    if Transformer.get_entities(dsl, [:entity]) != [] do
      with {:ok, dsl} <-
             Builder.add_change(dsl, Mana.Entity.Changed, on: [:create, :update, :destroy]),
           do: {:ok, Mana.NotAtomic.mark(dsl, fn _ -> true end)}
    else
      {:ok, dsl}
    end
  end
end

if Code.ensure_loaded?(Phoenix.Channel) do
  defmodule Mana.Entity.Channel do
    @moduledoc """
    Joins `entity:<type>:<id>` when the socket's user may read that record,
    `entity:<type>:for:<user>` only as that user, and `entity:<type>:all`
    when the resource's `watchers` let the user follow every record. Mount it for every live
    resource of the app, `channel "entity:*", Mana.Entity.Channel, assigns: %{otp_app: :my_app}`,
    or for a few, `assigns: %{resources: [MyApp.Booking]}`. Expects the
    socket to assign `:user`.
    """
    use Phoenix.Channel

    @impl true
    def join("entity:" <> rest, _params, socket) do
      user = socket.assigns[:user]
      resources = socket.assigns[:resources] || Mana.Entity.resources(socket.assigns[:otp_app])

      if may_join?(String.split(rest, ":"), user, resources),
        do: {:ok, socket},
        else: {:error, %{reason: "unauthorized"}}
    end

    defp may_join?([type, "all"], user, resources) do
      with resource when not is_nil(resource) <- find(resources, type),
           {module, function} <- Mana.Entity.watchers(resource) do
        user != nil and apply(module, function, [user]) == true
      else
        _ -> false
      end
    end

    defp may_join?([type, "for", id], user, resources),
      do:
        user && to_string(user.id) == id && Enum.any?(resources, &(Mana.Entity.type(&1) == type))

    defp may_join?([type, id], user, resources) do
      with resource when not is_nil(resource) <- find(resources, type),
           {:ok, _} <- Ash.get(resource, id, actor: user) do
        true
      else
        _ -> false
      end
    end

    defp may_join?(_topic, _user, _resources), do: false

    defp find(resources, type), do: Enum.find(resources, &(Mana.Entity.type(&1) == type))
  end
end
