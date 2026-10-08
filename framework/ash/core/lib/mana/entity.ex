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

  After each create, update or destroy the record's topic
  `entity:<type>:<id>`, and `entity:<type>:for:<user>` for each `audience`
  field, receive `"changed"` with only the id: clients read the record again
  through the API, with their own authorization, so a subscriber never sees
  data its policies would hide. `Mana.Entity.Channel` joins those topics after
  checking the reader may read the record (or is the audience user).

  A deadline is a durable Oban job scheduled when a change leaves the record
  satisfying `when`; when it runs it performs `action` only if `when` still
  holds, so a record that moved on is left alone. It survives deploys and
  multiple nodes; it is not an in-memory timer. `after` is `{amount, unit}` or
  `{Module, :function}` returning the `DateTime` for a record.
  """

  @deadline %Spark.Dsl.Entity{
    name: :deadline,
    target: Mana.Entity.Deadline,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      action: [type: :atom, required: true, doc: "The update action performed when the deadline passes."],
      when: [type: :any, required: true, doc: "The state the deadline watches; it fires only while this holds."],
      after: [type: :any, required: true, doc: "`{amount, unit}` from the change, or `{Module, :function}` → DateTime."]
    ]
  }

  @entity %Spark.Dsl.Section{
    name: :entity,
    imports: [Ash.Expr],
    entities: [@deadline],
    schema: [
      type: [type: :string, doc: "The topic name; the JSON:API type or the module's last segment by default."],
      broadcast: [type: :atom, doc: "A module with `broadcast/3` (a Phoenix endpoint)."],
      audience: [type: {:list, :atom}, default: [], doc: "User-id fields whose user follows every change."],
      watchers: [
        type: {:tuple, [:atom, :atom]},
        doc: "`{Module, :fun}`(user) → true for who may follow every record of the type on `entity:<type>:all` (an operator's queue)."
      ],
      queue: [type: :atom, default: :default, doc: "The Oban queue deadlines run on."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@entity], transformers: [Mana.Entity.Transformer]
  use Mana.Primitive, contract: "x-mana-entity", catalog: "entities"

  @impl Mana.Primitive
  def contract(resource) do
    [
      %{"topic" => type(resource), "audience" => Enum.map(audience(resource), &to_string/1), "deadlines" => Enum.map(deadlines(resource), &to_string(&1.name))}
      |> then(&if watchers(resource), do: Map.put(&1, "watchable", true), else: &1)
    ]
  end

  def deadlines(resource), do: Spark.Dsl.Extension.get_entities(resource, [:entity])

  @doc "Every live resource of `otp_app`'s domains."
  def resources(otp_app) do
    for domain <- Application.get_env(otp_app, :ash_domains, []),
        resource <- Ash.Domain.Info.resources(domain),
        __MODULE__ in Spark.extensions(resource),
        do: resource
  end
  def audience(resource), do: Spark.Dsl.Extension.get_opt(resource, [:entity], :audience, [])
  def watchers(resource), do: Spark.Dsl.Extension.get_opt(resource, [:entity], :watchers, nil)
  def broadcaster(resource), do: Spark.Dsl.Extension.get_opt(resource, [:entity], :broadcast, nil)
  def queue(resource), do: Spark.Dsl.Extension.get_opt(resource, [:entity], :queue, :default)

  def type(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:entity], :type, nil) ||
      (Code.ensure_loaded?(AshJsonApi.Resource.Info) && AshJsonApi.Resource in Spark.extensions(resource) &&
         to_string(AshJsonApi.Resource.Info.type(resource))) ||
      resource |> Module.split() |> List.last() |> Macro.underscore()
  end

  @doc "The topics a change to `record` is announced on."
  def topics(record) do
    resource = record.__struct__
    type = type(resource)

    ["entity:#{type}:#{record.id}" | for(field <- audience(resource), user = Map.get(record, field), do: "entity:#{type}:for:#{user}")] ++
      if(watchers(resource), do: ["entity:#{type}:all"], else: [])
  end

  @doc false
  def announce(record) do
    if broadcaster = broadcaster(record.__struct__) do
      for topic <- topics(record), do: broadcaster.broadcast(topic, "changed", %{"id" => record.id, "type" => type(record.__struct__)})
    end

    :ok
  end

  @doc false
  def holds?(expression, record) do
    resource = record.__struct__

    if Ash.DataLayer.data_layer_can?(resource, :filter) and Ash.Resource.Info.primary_key(resource) != [] do
      # Asked of the stored row, so the expression may reach relationships
      # (`exists(charges, ...)`) that the record in hand has not loaded.
      resource
      |> Ash.Query.do_filter(Map.to_list(Map.take(record, Ash.Resource.Info.primary_key(resource))))
      |> Ash.Query.do_filter(expression)
      |> Ash.exists?(authorize?: false)
    else
      match?({:ok, true}, Ash.Expr.eval(expression, record: record, resource: resource))
    end
  end

  @doc false
  def due_at(%{after: {amount, unit}}, _record) when is_integer(amount), do: DateTime.add(DateTime.utc_now(), amount, unit)
  def due_at(%{after: {module, function}}, record), do: apply(module, function, [record])

  @doc false
  def schedule(record) do
    resource = record.__struct__

    for deadline <- deadlines(resource), holds?(deadline.when, record) do
      inserter = Application.get_env(:mana_core, :deadline_inserter, &insert/1)
      args = %{"resource" => inspect(resource), "id" => record.id, "deadline" => to_string(deadline.name)}
      inserter.(%{args: args, queue: queue(resource), scheduled_at: due_at(deadline, record)})
    end

    :ok
  end

  defp insert(%{args: args, queue: queue, scheduled_at: at}),
    do: args |> Mana.Entity.Worker.new(queue: queue, scheduled_at: at) |> Oban.insert!()

  @doc "Runs a passed deadline when its record still satisfies it; otherwise does nothing."
  def run_deadline(resource, id, name) do
    deadline = Enum.find(deadlines(resource), &(to_string(&1.name) == name))

    with %{} <- deadline,
         {:ok, record} <- Ash.get(resource, id, authorize?: false),
         true <- holds?(deadline.when, record) do
      Ash.update!(record, %{}, action: deadline.action, authorize?: false, context: %{mana_deadline: deadline.name})
      :ok
    else
      _ -> :ok
    end
  end
end

defmodule Mana.Entity.Changed do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      if Mana.Entity.deadlines(record.__struct__) != [], do: Mana.Entity.schedule(record)
      Mana.Entity.announce(record)
      {:ok, record}
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Entity.Worker do
    @moduledoc false
    use Oban.Worker, max_attempts: 3

    @impl true
    def perform(%Oban.Job{args: %{"resource" => resource, "id" => id, "deadline" => name}}) do
      resource |> String.trim_leading("Elixir.") |> String.split(".") |> Module.safe_concat() |> Mana.Entity.run_deadline(id, name)
    end
  end
end

defmodule Mana.Entity.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(_), do: true

  def transform(dsl) do
    configured? =
      Transformer.get_option(dsl, [:entity], :broadcast) != nil or Transformer.get_entities(dsl, [:entity]) != []

    if configured?,
      do: Ash.Resource.Builder.add_change(dsl, Mana.Entity.Changed, on: [:create, :update, :destroy]),
      else: {:ok, dsl}
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

      case String.split(rest, ":") do
        [type, "all"] ->
          with resource when not is_nil(resource) <- Enum.find(resources, &(Mana.Entity.type(&1) == type)),
               {module, function} <- Mana.Entity.watchers(resource),
               true <- user != nil and apply(module, function, [user]) do
            {:ok, socket}
          else
            _ -> {:error, %{reason: "unauthorized"}}
          end

        [type, "for", id] ->
          if user && to_string(user.id) == id && Enum.any?(resources, &(Mana.Entity.type(&1) == type)),
            do: {:ok, socket},
            else: {:error, %{reason: "unauthorized"}}

        [type, id] ->
          with resource when not is_nil(resource) <- Enum.find(resources, &(Mana.Entity.type(&1) == type)),
               {:ok, _} <- Ash.get(resource, id, actor: user) do
            {:ok, socket}
          else
            _ -> {:error, %{reason: "unauthorized"}}
          end

        _ ->
          {:error, %{reason: "unauthorized"}}
      end
    end
  end
end
