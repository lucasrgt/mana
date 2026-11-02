defmodule Mana.Notifications.Notify do
  @moduledoc false
  defstruct [
    :action,
    :to,
    :template,
    :category,
    :opens,
    :channels,
    :when,
    :fallback,
    :payload,
    :__identifier__,
    :__spark_metadata__
  ]
end

defmodule Mana.Notifications.Sender do
  @moduledoc """
  Delivers what `Mana.Notifications` declares. `deliver/1` receives `to`
  (a user id), `template`, `category`, `channels`, `opens` (the deep link
  with `:id` filled), `payload` (`%{"<type>_id" => id}` plus the notice's
  `payload` attributes) and the `record`;
  it returns `:ok`, `{:error, reason}` when nothing went out, or
  `{:failed, [{channel, reason}]}` when only those channels failed.
  """
  @callback deliver(map()) :: :ok | {:error, term()} | {:failed, [{atom(), term()}]}
end

defmodule Mana.Notifications do
  @moduledoc """
  The notices a resource sends, declared next to the actions that cause
  them instead of inside each action:

      notifications do
        sender MyApp.Notifications.Sender
        notify :request, to: :host_id, template: "reservation.requested", category: :reservations, opens: "/bookings/:id"
        notify :cancel, to: :counterpart, template: "reservation.cancelled", category: :reservations
      end

  `sender` (a `Mana.Notifications.Sender`) receives one notice per
  recipient. `to` is a user-id attribute, a list of them, or `:counterpart` —
  every `Mana.Entity` audience member except the actor. `when` (an
  expression over the record) can hold a notice back; `channels`
  (`[:inbox]` by default) tell the sender where it goes. The contract
  carries `x-mana-notifications`, so clients route `opens` and group
  preferences by `category` from the same declaration.

  ## When a notice goes out

  Nothing is announced that rolled back. Where the app runs Oban (the
  `Oban` instance, on the repo the resource writes with), the action
  inserts one job per notice in its own transaction: the notice commits
  with the change, survives a crash after the commit, and a channel the
  sender failed is tried again by a job of its own (three attempts), so the
  channels that went out are not sent twice. Without Oban, or on another
  repo, the notice is sent once the outermost transaction commits (an Ash
  notifier), and a crash or a failing sender loses it. Through the outbox
  the sender's `record` is the record as stored when the job runs (nil once
  destroyed).

  Delivery follows the person, not the action: `preferences` drops the
  channels they turned off (the inbox always stays), `quiet_hours` holds
  outbound channels until their quiet hours end (a durable job), a repeat of
  the same notice about the same record inside `group_within` reaches the
  inbox only, marked `group: %{count: n}`, and `fallback: true` on a notice tries its channels
  in order (push, then email, then SMS) until the sender answers `:ok`.
  Each delivery joins the record's `Mana.History` when it has one: who was
  told, the channels that went out, those that failed and what was held.

  `group_within` counts in `Mana.Notifications.Groups`, a child the app
  starts in its supervision tree; without it the notifying actions of a
  resource that groups are refused. Its windows are per node: on several
  nodes a repeat may still reach outbound channels once per node. Grouping
  spares people repeats; it is not a guarantee, so it costs no database
  write per notice.
  """
  # Optional dependencies, called only when the app has them.
  @compile {:no_warn_undefined, [Mana.Notifications.Worker, Oban, AshPostgres.DataLayer.Info]}

  alias AshPostgres.DataLayer.Info, as: PostgresInfo
  alias Mana.Notifications.Groups
  alias Mana.Notifications.Worker
  alias Spark.Dsl.Extension

  @notify %Spark.Dsl.Entity{
    name: :notify,
    target: Mana.Notifications.Notify,
    args: [:action],
    identifier: {:auto, :unique_integer},
    schema: [
      action: [type: :atom, required: true, doc: "The action whose success sends it."],
      to: [
        type: {:or, [{:tuple, [:atom, :atom]}, :atom, {:list, :atom}]},
        required: true,
        doc:
          "User-id attribute(s), `:counterpart`, or `{Module, :fun}`(record) → user id(s) when the recipient is not on the record."
      ],
      template: [type: :string, required: true],
      category: [type: :atom, default: :general, doc: "What a person turns on or off together."],
      opens: [type: :string, doc: "The deep link it opens; `:id` is the record's id."],
      channels: [type: {:list, :atom}, default: [:inbox]],
      fallback: [
        type: :boolean,
        default: false,
        doc:
          "Channels are tried in order until one delivers (push, then email, then SMS) instead of all."
      ],
      when: [type: :any, doc: "An expression over the record; sent only while it holds."],
      payload: [
        type: {:or, [{:tuple, [:atom, :atom]}, {:list, :atom}]},
        default: [],
        doc:
          "Attributes of the record copied into the payload for the template's text, or `{Module, :fun}`(record) → map."
      ]
    ]
  }

  @notifications %Spark.Dsl.Section{
    name: :notifications,
    imports: [Ash.Expr],
    entities: [@notify],
    schema: [
      sender: [type: :atom, required: true, doc: "A `Mana.Notifications.Sender`."],
      preferences: [
        type: {:tuple, [:atom, :atom]},
        doc: "`{Module, :fun}`(user_id, category, channel) → boolean; the inbox is always kept."
      ],
      quiet_hours: [
        type: {:tuple, [:atom, :atom]},
        doc: "`{Module, :fun}`(user_id) → nil, or the DateTime the recipient's quiet hours end."
      ],
      group_within: [
        type: :any,
        doc:
          "`{amount, unit}`: a notice repeating one already sent to the same person about the same record inside it goes to the inbox only, marked as grouped."
      ],
      queue: [
        type: :atom,
        default: :default,
        doc: "The Oban queue of notices held for quiet hours."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@notifications],
    transformers: [Mana.Notifications.Transformer]

  use Mana.Primitive,
    contract: "x-mana-notifications",
    catalog: "notifications",
    moments: [:observe, :fake]

  @doc "Moments `observe`: the notices `record` sends after `action` by `actor`, without sending them."
  def observe(record, action, actor),
    do: record |> notices(action, actor) |> Enum.map(&Map.delete(&1, :record))

  @doc """
  Moments `fake`: runs `fun` with every notice held instead of delivered,
  and answers `{result, notices}`, so a Moment checks who would have heard
  what without anyone hearing it.
  """
  def fake(fun) do
    previous = Process.put(:mana_dry_run, [])

    try do
      result = fun.()
      {result, Enum.reverse(Process.get(:mana_dry_run) || [])}
    after
      if previous, do: Process.put(:mana_dry_run, previous), else: Process.delete(:mana_dry_run)
    end
  end

  def declared(resource), do: Extension.get_entities(resource, [:notifications])
  def sender(resource), do: Extension.get_opt(resource, [:notifications], :sender, nil)

  @impl Mana.Primitive
  def contract(resource) do
    for notify <- declared(resource) do
      %{
        "action" => to_string(notify.action),
        "template" => notify.template,
        "category" => to_string(notify.category),
        "channels" => Enum.map(notify.channels, &to_string/1)
      }
      |> then(&if notify.opens, do: Map.put(&1, "opens", notify.opens), else: &1)
    end
  end

  @doc "The notices `record` sends after `action` performed by `actor`."
  def notices(record, action, actor) do
    resource = record.__struct__
    type = Mana.Entity.type(resource)

    for notify <- declared(resource),
        notify.action == action,
        holds?(notify.when, record),
        to <- recipients(notify.to, record, actor) do
      %{
        to: to,
        template: notify.template,
        category: notify.category,
        channels: notify.channels,
        opens: notify.opens && String.replace(notify.opens, ":id", to_string(record.id)),
        payload: payload(notify, record, type),
        record: record
      }
    end
  end

  defp payload(%{payload: {module, function}}, record, type),
    do:
      record
      |> then(&apply(module, function, [&1]))
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("#{type}_id", record.id)

  defp payload(notify, record, type) do
    for field <- notify.payload,
        value <- [Map.get(record, field)],
        not is_nil(value),
        into: %{"#{type}_id" => record.id} do
      {to_string(field),
       if(is_atom(value) and not is_boolean(value), do: to_string(value), else: value)}
    end
  end

  defp holds?(nil, _record), do: true

  defp holds?(expression, record),
    do:
      match?({:ok, true}, Ash.Expr.eval(expression, record: record, resource: record.__struct__))

  defp recipients(:counterpart, record, actor) do
    me = actor && Map.get(actor, :id)

    for field <- Mana.Entity.audience(record.__struct__),
        id = Map.get(record, field),
        id != me,
        uniq: true,
        do: id
  end

  defp recipients({module, function}, record, _actor),
    do: for(id <- List.wrap(apply(module, function, [record])), id, uniq: true, do: id)

  defp recipients(fields, record, _actor),
    do: for(field <- List.wrap(fields), id = Map.get(record, field), uniq: true, do: id)

  @doc false
  def send_all(record, action, actor) do
    notices = notices(record, action, actor)

    case Process.get(:mana_dry_run) do
      held when is_list(held) ->
        Process.put(
          :mana_dry_run,
          Enum.reverse(Enum.map(notices, &Map.delete(&1, :record))) ++ held
        )

      nil ->
        Enum.each(notices, &deliver(record.__struct__, &1))
    end
  end

  @doc false
  def enqueue_all(record, action, actor) do
    for notice <- notices(record, action, actor),
        do: enqueue(record.__struct__, notice, "deliver", nil)
  end

  @doc """
  Whether `resource`'s notices go through the outbox: the `Oban` instance is
  running and its jobs commit with the resource's writes (the same repo, or
  a data layer without transactions).
  """
  def outbox?(resource) do
    Code.ensure_loaded?(Oban) and Process.whereis(Oban.Registry) != nil and
      Oban.whereis(Oban) != nil and commits_with?(resource, Oban.config().repo)
  end

  defp commits_with?(resource, repo) do
    if Ash.DataLayer.data_layer_can?(resource, :transact),
      do:
        Ash.DataLayer.data_layer(resource) == AshPostgres.DataLayer and
          PostgresInfo.repo(resource, :mutate) == repo,
      else: true
  end

  @doc false
  def grouped?(resource), do: opt(resource, :group_within) != nil

  defp opt(resource, key, default \\ nil),
    do: Extension.get_opt(resource, [:notifications], key, default)

  @doc """
  Sends one notice the way the resource declares: channels the recipient
  turned off are dropped (the inbox stays), a repeat inside `group_within`
  goes to the inbox only, outbound channels wait out quiet hours (held as a
  durable job), and with `fallback` the channels are tried in order until
  one delivers. Answers the channels that went out now.
  """
  def deliver(resource, notice), do: resource |> deliver_now(notice) |> elem(0)

  defp deliver_now(resource, notice) do
    {notice, channels} = group(resource, notice, wanted_channels(resource, notice))
    {now, later} = Enum.split_with(channels, &(&1 == :inbox))
    {now, held_until} = quiet_hours(resource, notice, now, later)

    if held_until, do: enqueue(resource, %{notice | channels: later}, "send", held_until)

    {sent, failed} =
      send_channels(sender(resource), notice, now, fallback?(resource, notice.template))

    record(
      resource,
      notice,
      sent,
      failed,
      held_until && %{"channels" => later, "until" => held_until}
    )

    {sent, failed}
  end

  defp send_now(resource, notice, fallback) do
    {sent, failed} = send_channels(sender(resource), notice, notice.channels, fallback)
    record(resource, notice, sent, failed, nil)
    {sent, failed}
  end

  defp wanted_channels(resource, notice) do
    case opt(resource, :preferences) do
      {m, f} ->
        Enum.filter(
          notice.channels,
          &(&1 == :inbox or apply(m, f, [notice.to, notice.category, &1]))
        )

      nil ->
        notice.channels
    end
  end

  defp quiet_hours(_resource, _notice, now, []), do: {now, nil}

  defp quiet_hours(resource, notice, now, later) do
    with {m, f} <- opt(resource, :quiet_hours),
         %DateTime{} = until <- apply(m, f, [notice.to]) do
      {now, until}
    else
      _ -> {now ++ later, nil}
    end
  end

  # Each delivery joins the history of the record it is about: who was told,
  # on which channels, what waited for quiet hours and what failed.
  defp record(resource, notice, sent, failed, held) do
    if sent != [] or failed != [] or held do
      Mana.History.note(resource, notice.payload["#{Mana.Entity.type(resource)}_id"], %{
        action: :notify,
        via: "notifications",
        summary: "notified #{notice.template}",
        after: %{
          "template" => notice.template,
          "to" => notice.to,
          "sent" => sent,
          "failed" => Keyword.keys(failed),
          "held" => held
        },
        outcome: if(sent == [] and failed != [], do: :failed, else: :done),
        error: if(failed != [], do: describe(failed))
      })
    end
  end

  defp describe(failed),
    do: Enum.map_join(failed, "; ", fn {channel, reason} -> "#{channel}: #{inspect(reason)}" end)

  defp fallback?(resource, template),
    do: Enum.any?(declared(resource), &(&1.template == template and &1.fallback))

  defp send_channels(_sender, _notice, [], _fallback), do: {[], []}

  defp send_channels(sender, notice, channels, false) do
    case sender.deliver(%{notice | channels: channels}) do
      {:error, reason} -> {[], Enum.map(channels, &{&1, reason})}
      {:failed, failed} -> {channels -- Keyword.keys(failed), failed}
      _ -> {channels, []}
    end
  end

  defp send_channels(sender, notice, channels, true) do
    {inbox, outbound} = Enum.split_with(channels, &(&1 == :inbox))

    {sent, failed} =
      if inbox != [], do: send_channels(sender, notice, inbox, false), else: {[], []}

    Enum.reduce_while(outbound, {sent, failed}, fn channel, {sent, failed} ->
      case sender.deliver(%{notice | channels: [channel]}) do
        {:error, reason} -> {:cont, {sent, failed ++ [{channel, reason}]}}
        {:failed, more} -> {:cont, {sent, failed ++ more}}
        _ -> {:halt, {sent ++ [channel], failed}}
      end
    end)
  end

  defp group(resource, notice, channels) do
    case opt(resource, :group_within) do
      {amount, unit} ->
        key = {notice.to, notice.template, notice.payload}

        case Groups.count(key, :timer.seconds(seconds(amount, unit))) do
          1 ->
            {notice, channels}

          count ->
            {Map.put(notice, :group, %{count: count}), Enum.filter(channels, &(&1 == :inbox))}
        end

      nil ->
        {notice, channels}
    end
  end

  defp seconds(n, :second), do: n
  defp seconds(n, :minute), do: n * 60
  defp seconds(n, :hour), do: n * 3600
  defp seconds(n, :day), do: n * 86_400

  defp enqueue(resource, notice, stage, at) do
    args = %{"resource" => inspect(resource), "stage" => stage, "notice" => encode(notice)}
    inserter = Application.get_env(:mana_core, :deadline_inserter, &insert/1)
    inserter.(%{args: args, queue: opt(resource, :queue, :default), scheduled_at: at})
  end

  defp insert(%{args: args, queue: queue, scheduled_at: at}),
    do:
      args
      |> Worker.new([queue: queue] ++ if(at, do: [scheduled_at: at], else: []))
      |> Oban.insert!()

  defp encode(notice) do
    notice
    |> Map.delete(:record)
    |> Map.update!(:category, &to_string/1)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp decode(resource, notice) do
    %{
      to: notice["to"],
      template: notice["template"],
      category: String.to_existing_atom(notice["category"]),
      channels: Enum.map(notice["channels"], &String.to_existing_atom/1),
      opens: notice["opens"],
      payload: notice["payload"],
      record: stored(resource, notice["payload"])
    }
    |> then(
      &if notice["group"], do: Map.put(&1, :group, %{count: notice["group"]["count"]}), else: &1
    )
  end

  defp stored(resource, payload) do
    with id when not is_nil(id) <- payload["#{Mana.Entity.type(resource)}_id"],
         {:ok, record} <- Ash.get(resource, id, authorize?: false, error?: false) do
      record
    else
      _ -> nil
    end
  end

  @doc false
  def deliver_held(resource, notice) do
    notice = decode(resource, notice)
    {sent, _failed} = send_now(resource, notice, fallback?(resource, notice.template))
    sent
  end

  @doc false
  # A "deliver" job carries a notice from the outbox through every delivery
  # rule; a "send" job (held for quiet hours, or a retry) goes to its channels
  # as they are. Only the channels that failed are tried again, so none that
  # went out is sent twice.
  def perform(resource, notice, stage) do
    notice = decode(resource, notice)
    fallback = fallback?(resource, notice.template)

    {sent, failed} =
      if stage == "deliver",
        do: deliver_now(resource, notice),
        else: send_now(resource, notice, fallback)

    case retry(sent, failed, fallback) do
      [] ->
        :ok

      _ when stage == "send" and sent == [] ->
        {:error, describe(failed)}

      channels ->
        enqueue(resource, %{notice | channels: channels}, "send", nil)
        :ok
    end
  end

  # With fallback, one outbound channel that delivered is enough.
  defp retry(sent, failed, true) do
    {inbox, outbound} =
      failed |> Keyword.keys() |> Enum.uniq() |> Enum.split_with(&(&1 == :inbox))

    if Enum.any?(sent, &(&1 != :inbox)), do: inbox, else: inbox ++ outbound
  end

  defp retry(_sent, failed, false), do: failed |> Keyword.keys() |> Enum.uniq()
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Notifications.Worker do
    @moduledoc false
    use Oban.Worker, max_attempts: 3

    @impl true
    def perform(%Oban.Job{args: %{"resource" => resource, "notice" => notice} = args}) do
      resource
      |> String.trim_leading("Elixir.")
      |> String.split(".")
      |> Module.safe_concat()
      |> Mana.Notifications.perform(notice, Map.get(args, "stage", "send"))
    end
  end
end

defmodule Mana.Notifications.Send do
  @moduledoc false
  # A dry run (Mana.Checkpoint, Moments' fake/1) is usually rolled back, so it
  # never commits: what it would send is held here, as the action happens.
  # The outbox's jobs are inserted here too, inside the action's transaction,
  # so they commit or roll back with it.
  use Ash.Resource.Change
  alias Mana.Notifications.Groups

  @impl true
  def change(changeset, _opts, context) do
    resource = changeset.resource

    cond do
      not Enum.any?(Mana.Notifications.declared(resource), &(&1.action == changeset.action.name)) ->
        changeset

      # Refused before anything is written, rather than raising after commit.
      Mana.Notifications.grouped?(resource) and not Groups.started?() ->
        Ash.Changeset.add_error(changeset, Groups.not_running())

      true ->
        Ash.Changeset.after_action(changeset, &queue(&1, &2, context.actor))
    end
  end

  defp queue(changeset, record, actor) do
    name = changeset.action.name

    cond do
      Process.get(:mana_dry_run) ->
        Mana.Notifications.send_all(record, name, actor)
        {:ok, record}

      Mana.Notifications.outbox?(changeset.resource) ->
        Mana.Notifications.enqueue_all(record, name, actor)
        {:ok, Ash.Resource.put_metadata(record, :mana_notices, :queued)}

      true ->
        {:ok, record}
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end

defmodule Mana.Notifications.Notifier do
  @moduledoc false
  # Without the outbox: an Ash notifier runs once the outermost transaction
  # commits and never for one that rolls back, so a notice never tells of a
  # change that did not happen, however deep the action that made it.
  use Ash.Notifier

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: resource,
        action: %{name: name},
        data: record,
        actor: actor
      }) do
    if is_nil(Process.get(:mana_dry_run)) and
         Ash.Resource.get_metadata(record, :mana_notices) != :queued and
         Enum.any?(Mana.Notifications.declared(resource), &(&1.action == name)),
       do: Mana.Notifications.send_all(record, name, actor)

    :ok
  end
end

defmodule Mana.Notifications.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(_), do: true

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:notifications]) do
      [] ->
        {:ok, dsl}

      _ ->
        notifiers = Transformer.get_persisted(dsl, :simple_notifiers, [])

        dsl
        |> Transformer.persist(
          :simple_notifiers,
          Enum.uniq(notifiers ++ [Mana.Notifications.Notifier])
        )
        |> Builder.add_change(Mana.Notifications.Send, on: [:create, :update, :destroy])
    end
  end
end
