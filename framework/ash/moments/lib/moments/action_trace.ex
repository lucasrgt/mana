defmodule Moments.ActionTrace do
  @moduledoc "Bounded request-local Ash action observations. No arguments, actor values or error payloads."
  @behaviour Ash.Tracer
  @key {__MODULE__, :context}
  @stack {__MODULE__, :stack}
  @limit 16
  @types [:action, :bulk_create, :bulk_update, :bulk_destroy]

  def begin_request(gesture) do
    discard()
    table = :ets.new(__MODULE__, [:set, :public, write_concurrency: true])
    :ets.insert(table, {:count, 0})

    Process.put(@key, %{
      table: table,
      started: System.monotonic_time(),
      gesture: gesture,
      request: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    })

    :ok
  end

  def finish_request do
    case Process.get(@key) do
      nil ->
        nil

      context ->
        count = :ets.lookup_element(context.table, :count, 2)
        actions = for {id, event} <- :ets.tab2list(context.table), is_integer(id), do: {id, event}

        changes = for {{:change, id}, change} <- :ets.tab2list(context.table), do: {id, change}

        result = %{
          version: if(changes == [], do: 2, else: 3),
          gesture: context.gesture,
          request: context.request,
          truncated: count > @limit,
          actions: actions |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1)),
          scope: "request-actions-only",
          coverage: "not-established"
        }

        result = if changes == [], do: result, else: Map.put(result, :changes, changes |> Enum.sort() |> Enum.map(&elem(&1, 1)))
        result = Map.put(result, :profile, %{
          requestDurationUs: elapsed(context.started),
          database: database_profile(context.table)
        })

        discard()
        result
    end
  end

  def discard do
    if context = Process.delete(@key) do
      if :ets.info(context.table, :owner) == self(), do: :ets.delete(context.table)
    end

    Process.delete(@stack)
    :ok
  end

  @impl true
  def trace_type?(type), do: type in @types and !is_nil(Process.get(@key))
  @impl true
  def get_span_context, do: Process.get(@key)
  @impl true
  def set_span_context(context) do
    Process.put(@key, context)
    :ok
  end

  @impl true
  def start_span(type, _name) do
    Process.put(@stack, [
      %{metadata: %{kind: to_string(type)}, error: false, started: System.monotonic_time()} | Process.get(@stack, [])
    ])

    :ok
  end

  @impl true
  def set_metadata(type, metadata) when type in @types do
    update(fn span ->
      # Discard all other keys BEFORE retaining anything in process state.
      fields =
        for key <- [:resource, :action, :domain],
            value = Map.get(metadata, key),
            is_atom(value) and !is_nil(value),
            into: %{},
            do: {key, if(key == :action, do: to_string(value), else: inspect(value))}

      fields =
        case Map.get(metadata, :authorize?) do
          value when is_boolean(value) -> Map.put(fields, :authorization_requested, value)
          _ -> fields
        end

      %{span | metadata: Map.merge(span.metadata, fields)}
    end)
  end

  def set_metadata(_, _), do: :ok
  @impl true
  def set_error(_error, _options), do: update(&%{&1 | error: true})
  @impl true
  def set_handled_error(_error, _options), do: update(&%{&1 | error: true})

  def observe_bulk(kind, domain, resource, action, duration \\ nil)
      when kind in [:bulk_create, :bulk_update, :bulk_destroy] do
    fields = %{
      kind: to_string(kind),
      domain: inspect(domain),
      resource: inspect(resource),
      action: to_string(action)
    }

    # If the caller explicitly passed our tracer, its outer span will record
    # this event with richer metadata. Global tracer options miss some bulk paths.
    already_traced =
      case Process.get(@stack, []) do
        [%{metadata: metadata} | _] -> Map.take(metadata, Map.keys(fields)) == fields
        _ -> false
      end

    fields = if is_integer(duration) and duration >= 0,
      do: Map.put(fields, :durationUs, System.convert_time_unit(duration, :native, :microsecond)), else: fields
    if !already_traced, do: retain(Map.put(fields, :outcome, "span-finished"))
    :ok
  end

  @impl true
  def stop_span do
    case {Process.get(@key), Process.get(@stack, [])} do
      {%{table: _}, [span | rest]} ->
        Process.put(@stack, rest)

        if Map.has_key?(span.metadata, :resource) and Map.has_key?(span.metadata, :action) do
          retain(
            Map.put(
              Map.put(span.metadata, :durationUs, elapsed(span.started)),
              :outcome,
              if(span.error, do: "error-reported", else: "span-finished")
            )
          )
        end

      _ ->
        :ok
    end

    :ok
  end

  # Called by the consumer's exact Repo telemetry event, in the query caller.
  # Aggregates have constant storage and retain no query text, params or errors.
  # Context inherited by Ash tasks shares this request-owned table; unrelated
  # processes and work after the HTTP receipt closes are not attributed.
  def observe_query(measurements) do
    if context = Process.get(@key) do
      totals = for key <- [:total_time, :query_time, :queue_time, :decode_time] do
        value = Map.get(measurements, key, 0)
        if is_integer(value) and value >= 0, do: value, else: 0
      end
      [total, query, queue, decode] = totals
      :ets.update_counter(context.table, :database,
        [{2, 1}, {3, total}, {4, query}, {5, queue}, {6, decode}],
        {:database, 0, 0, 0, 0, 0})
    end
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp database_profile(table) do
    case :ets.lookup(table, :database) do
      [{:database, count, total, query, queue, decode}] ->
        %{status: "observed", queries: count,
          totalUs: System.convert_time_unit(total, :native, :microsecond),
          queryUs: System.convert_time_unit(query, :native, :microsecond),
          queueUs: System.convert_time_unit(queue, :native, :microsecond),
          decodeUs: System.convert_time_unit(decode, :native, :microsecond)}
      [] -> %{status: "not-observed"}
    end
  end

  @doc """
  Records which record a request changed, for whoever tracks changes (a
  history): `resource`, `subject` (the record's id), `action`, `outcome`
  (`done` or `failed`) and the changed `fields` — names only, never values.
  At most #{@limit} per request; nothing outside a request.
  """
  def annotate_change(%{resource: resource, subject: subject, action: action, outcome: outcome, fields: fields})
      when is_binary(subject) and outcome in ["done", "failed"] and is_list(fields) do
    if context = Process.get(@key) do
      id = :ets.update_counter(context.table, :changes, {2, 1}, {:changes, 0})

      if id <= @limit do
        change = %{
          resource: inspect(resource),
          subject: String.slice(subject, 0, 64),
          action: to_string(action),
          outcome: outcome,
          fields: fields |> Enum.map(&to_string/1) |> Enum.take(32)
        }

        :ets.insert(context.table, {{:change, id}, change})
      end
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp elapsed(started), do: System.convert_time_unit(System.monotonic_time() - started, :native, :microsecond)

  defp retain(event) do
    if context = Process.get(@key) do
      id = :ets.update_counter(context.table, :count, {2, 1})
      if id <= @limit, do: :ets.insert(context.table, {id, event})
    end

    :ok
  rescue
    # Detached work can outlive its request. It cannot extend a sealed receipt.
    ArgumentError -> :ok
  end

  defp update(fun) do
    case Process.get(@stack, []) do
      [span | rest] -> Process.put(@stack, [fun.(span) | rest])
      [] -> :ok
    end

    :ok
  end
end
