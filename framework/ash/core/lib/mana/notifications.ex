defmodule Mana.Notifications.Notify do
  @moduledoc false
  defstruct [:action, :to, :template, :category, :opens, :channels, :when, :fallback, :payload, :__identifier__, :__spark_metadata__]
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

  Once the action has committed (nothing is announced that rolled back),
  `sender` (a `Mana.Notifications.Sender`) receives one notice per recipient. `to` is a user-id attribute, a list of
  them, or `:counterpart` — every `Mana.Entity` audience member except the
  actor. `when` (an expression over the record) can hold a notice back;
  `channels` (`[:inbox]` by default) tell the sender where it goes. The
  contract carries `x-mana-notifications`, so clients route `opens` and group
  preferences by `category` from the same declaration.

  Delivery follows the person, not the action: `preferences` drops the
  channels they turned off (the inbox always stays), `quiet_hours` holds
  outbound channels until their quiet hours end (a durable job), a repeat of
  the same notice about the same record inside `group_within` reaches the
  inbox only, marked `group: %{count: n}`, and `fallback: true` on a notice tries its channels
  in order (push, then email, then SMS) until the sender answers `:ok`.
  Each delivery joins the record's `Mana.History` when it has one: who was
  told, the channels that went out, those that failed and what was held.
  """

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
        doc: "User-id attribute(s), `:counterpart`, or `{Module, :fun}`(record) → user id(s) when the recipient is not on the record."
      ],
      template: [type: :string, required: true],
      category: [type: :atom, default: :general, doc: "What a person turns on or off together."],
      opens: [type: :string, doc: "The deep link it opens; `:id` is the record's id."],
      channels: [type: {:list, :atom}, default: [:inbox]],
      fallback: [type: :boolean, default: false, doc: "Channels are tried in order until one delivers (push, then email, then SMS) instead of all."],
      when: [type: :any, doc: "An expression over the record; sent only while it holds."],
      payload: [
        type: {:or, [{:tuple, [:atom, :atom]}, {:list, :atom}]},
        default: [],
        doc: "Attributes of the record copied into the payload for the template's text, or `{Module, :fun}`(record) → map."
      ]
    ]
  }

  @notifications %Spark.Dsl.Section{
    name: :notifications,
    imports: [Ash.Expr],
    entities: [@notify],
    schema: [
      sender: [type: :atom, required: true, doc: "A `Mana.Notifications.Sender`."],
      preferences: [type: {:tuple, [:atom, :atom]}, doc: "`{Module, :fun}`(user_id, category, channel) → boolean; the inbox is always kept."],
      quiet_hours: [type: {:tuple, [:atom, :atom]}, doc: "`{Module, :fun}`(user_id) → nil, or the DateTime the recipient's quiet hours end."],
      group_within: [type: :any, doc: "`{amount, unit}`: a notice repeating one already sent to the same person about the same record inside it goes to the inbox only, marked as grouped."],
      queue: [type: :atom, default: :default, doc: "The Oban queue of notices held for quiet hours."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@notifications], transformers: [Mana.Notifications.Transformer]
  use Mana.Primitive, contract: "x-mana-notifications", catalog: "notifications", moments: [:observe, :fake]

  @doc "Moments `observe`: the notices `record` sends after `action` by `actor`, without sending them."
  def observe(record, action, actor), do: record |> notices(action, actor) |> Enum.map(&Map.delete(&1, :record))

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

  def declared(resource), do: Spark.Dsl.Extension.get_entities(resource, [:notifications])
  def sender(resource), do: Spark.Dsl.Extension.get_opt(resource, [:notifications], :sender, nil)

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
    do: record |> then(&apply(module, function, [&1])) |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("#{type}_id", record.id)

  defp payload(notify, record, type) do
    for field <- notify.payload, value <- [Map.get(record, field)], not is_nil(value), into: %{"#{type}_id" => record.id} do
      {to_string(field), if(is_atom(value) and not is_boolean(value), do: to_string(value), else: value)}
    end
  end

  defp holds?(nil, _record), do: true
  defp holds?(expression, record), do: match?({:ok, true}, Ash.Expr.eval(expression, record: record, resource: record.__struct__))

  defp recipients(:counterpart, record, actor) do
    me = actor && Map.get(actor, :id)
    for field <- Mana.Entity.audience(record.__struct__), id = Map.get(record, field), id != me, uniq: true, do: id
  end

  defp recipients({module, function}, record, _actor), do: for(id <- List.wrap(apply(module, function, [record])), id, uniq: true, do: id)

  defp recipients(fields, record, _actor), do: for(field <- List.wrap(fields), id = Map.get(record, field), uniq: true, do: id)

  @doc false
  def send_all(record, action, actor) do
    notices = notices(record, action, actor)

    case Process.get(:mana_dry_run) do
      held when is_list(held) ->
        Process.put(:mana_dry_run, Enum.reverse(Enum.map(notices, &Map.delete(&1, :record))) ++ held)

      nil ->
        Enum.each(notices, &deliver(record.__struct__, &1))
    end
  end

  defp opt(resource, key, default \\ nil), do: Spark.Dsl.Extension.get_opt(resource, [:notifications], key, default)

  @doc """
  Sends one notice the way the resource declares: channels the recipient
  turned off are dropped (the inbox stays), a repeat inside `group_within`
  goes to the inbox only, outbound channels wait out quiet hours (held as a
  durable job), and with `fallback` the channels are tried in order until
  one delivers. Answers the channels that went out now.
  """
  def deliver(resource, notice) do
    sender = sender(resource)

    channels =
      case opt(resource, :preferences) do
        {m, f} -> Enum.filter(notice.channels, &(&1 == :inbox or apply(m, f, [notice.to, notice.category, &1])))
        nil -> notice.channels
      end

    {notice, channels} = group(resource, notice, channels)
    {now, later} = Enum.split_with(channels, &(&1 == :inbox))

    {now, held_until} =
      case {later, opt(resource, :quiet_hours)} do
        {[_ | _], {m, f}} ->
          case apply(m, f, [notice.to]) do
            %DateTime{} = until -> {now, until}
            _ -> {now ++ later, nil}
          end

        _ ->
          {now ++ later, nil}
      end

    if held_until, do: hold(resource, notice, later, held_until)
    {sent, failed} = send_channels(sender, notice, now, fallback?(resource, notice.template))
    record(resource, notice, sent, failed, held_until && %{"channels" => later, "until" => held_until})
    sent
  end

  # Each delivery joins the history of the record it is about: who was told,
  # on which channels, what waited for quiet hours and what failed.
  defp record(resource, notice, sent, failed, held) do
    if sent != [] or failed != [] or held do
      Mana.History.note(resource, notice.payload["#{Mana.Entity.type(resource)}_id"], %{
        action: :notify,
        via: "notifications",
        summary: "notified #{notice.template}",
        after: %{"template" => notice.template, "to" => notice.to, "sent" => sent, "failed" => Keyword.keys(failed), "held" => held},
        outcome: if(sent == [] and failed != [], do: :failed, else: :done),
        error: if(failed != [], do: failed |> Enum.map(fn {channel, reason} -> "#{channel}: #{inspect(reason)}" end) |> Enum.join("; "))
      })
    end
  end

  defp fallback?(resource, template), do: Enum.any?(declared(resource), &(&1.template == template and &1.fallback))

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
    {sent, failed} = if inbox != [], do: send_channels(sender, notice, inbox, false), else: {[], []}

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
        key = {__MODULE__, :sent, notice.to, notice.template, notice.payload}
        now = System.system_time(:millisecond)
        window = System.convert_time_unit(1, :second, :millisecond) * seconds(amount, unit)

        case :persistent_term.get(key, nil) do
          {at, count} when now - at < window ->
            :persistent_term.put(key, {at, count + 1})
            {Map.put(notice, :group, %{count: count + 1}), Enum.filter(channels, &(&1 == :inbox))}

          _ ->
            :persistent_term.put(key, {now, 1})
            {notice, channels}
        end

      nil ->
        {notice, channels}
    end
  end

  defp seconds(n, :second), do: n
  defp seconds(n, :minute), do: n * 60
  defp seconds(n, :hour), do: n * 3600
  defp seconds(n, :day), do: n * 86_400

  defp hold(resource, notice, channels, until) do
    args = %{
      "resource" => inspect(resource),
      "notice" => notice |> Map.delete(:record) |> Map.put(:channels, channels) |> Map.update!(:category, &to_string/1) |> Map.new(fn {k, v} -> {to_string(k), v} end)
    }

    inserter = Application.get_env(:mana_core, :deadline_inserter, &insert/1)
    inserter.(%{args: args, queue: opt(resource, :queue, :default), scheduled_at: until})
  end

  defp insert(%{args: args, queue: queue, scheduled_at: at}),
    do: args |> Mana.Notifications.Worker.new(queue: queue, scheduled_at: at) |> Oban.insert!()

  @doc false
  def deliver_held(resource, notice) do
    notice = %{
      to: notice["to"],
      template: notice["template"],
      category: String.to_existing_atom(notice["category"]),
      channels: Enum.map(notice["channels"], &String.to_existing_atom/1),
      opens: notice["opens"],
      payload: notice["payload"],
      record: nil
    }

    {sent, failed} = send_channels(sender(resource), notice, notice.channels, fallback?(resource, notice.template))
    record(resource, notice, sent, failed, nil)
    sent
  end
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Notifications.Worker do
    @moduledoc false
    use Oban.Worker, max_attempts: 3

    @impl true
    def perform(%Oban.Job{args: %{"resource" => resource, "notice" => notice}}) do
      resource |> String.trim_leading("Elixir.") |> String.split(".") |> Module.safe_concat() |> Mana.Notifications.deliver_held(notice)
      :ok
    end
  end
end

defmodule Mana.Notifications.Send do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    if Enum.any?(Mana.Notifications.declared(changeset.resource), &(&1.action == changeset.action.name)) do
      Ash.Changeset.after_transaction(changeset, fn
        _changeset, {:ok, record} ->
          Mana.Notifications.send_all(record, changeset.action.name, context.actor)
          {:ok, record}

        _changeset, result ->
          result
      end)
    else
      changeset
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end

defmodule Mana.Notifications.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(_), do: true

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:notifications]) do
      [] -> {:ok, dsl}
      _ -> Ash.Resource.Builder.add_change(dsl, Mana.Notifications.Send, on: [:create, :update, :destroy])
    end
  end
end
