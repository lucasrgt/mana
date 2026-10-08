defmodule Mana.Runtime.Metrics do
  @moduledoc "Bounded, credential-free metrics from native Bandit/Ecto/Oban telemetry."
  import Telemetry.Metrics

  def child_spec(options) do
    Peep.child_spec(
      name: Keyword.fetch!(options, :name), metrics: definitions(options)
    )
  end

  def scrape(name), do: name |> Peep.get_all_metrics() |> Peep.Prometheus.export()

  def definitions(options) do
    endpoint = Keyword.fetch!(options, :endpoint)
    repo_event = Keyword.fetch!(options, :repo_event)
    oban = Keyword.fetch!(options, :oban)
    queues = Keyword.fetch!(options, :queues) |> Enum.map(&to_string/1)

    unless length(queues) <= 32 and Enum.all?(queues, &(byte_size(&1) <= 64)),
      do: raise(ArgumentError, "Metrics require at most 32 declared queue labels")

    http = [event_name: [:bandit, :request, :stop], measurement: :duration,
      keep: &http?(&1, endpoint), tags: [:method, :status_class], tag_values: &http_tags/1]
    query = [event_name: repo_event, measurement: :total_time,
      tags: [:result], tag_values: &query_tags/1]
    job = [keep: &(get_in(&1, [:conf, Access.key(:name)]) == oban),
      tags: [:queue], tag_values: &%{queue: queue(&1, queues)}]

    [
      counter("mana.http.requests.total", http),
      duration("mana.http.duration.microseconds", http),
      counter("mana.http.exceptions.total", event_name: [:bandit, :request, :exception],
        measurement: :monotonic_time, keep: &http?(&1, endpoint)),
      counter("mana.db.queries.total", query),
      duration("mana.db.query.duration.microseconds", query),
      duration("mana.db.queue.duration.microseconds", Keyword.put(query, :measurement, :queue_time)),
      last_value("mana.db.last.error.timestamp.seconds", event_name: repo_event,
        measurement: fn _ -> System.system_time(:second) end,
        keep: &match?(%{result: {:error, _}}, &1)),
      counter("mana.jobs.finished.total", job ++ [event_name: [:oban, :job, :stop], measurement: :duration]),
      counter("mana.jobs.failures.total", job ++ [event_name: [:oban, :job, :exception], measurement: :duration]),
      last_value("mana.jobs.last.failure.timestamp.seconds", job ++ [event_name: [:oban, :job, :exception],
        measurement: fn _ -> System.system_time(:second) end]),
      duration("mana.jobs.duration.microseconds", job ++ [event_name: [:oban, :job, :stop], measurement: :duration]),
      duration("mana.jobs.queue.duration.microseconds", job ++ [event_name: [:oban, :job, :stop], measurement: :queue_time])
    ] ++ queue_observations(options, queues)
  end

  # The consumer owns its durable queue query and indexes. These definitions
  # consume only bounded, aggregate observations, never job IDs or arguments.
  defp queue_observations(options, queues) do
    case Keyword.get(options, :queue_event) do
      nil -> []
      event ->
        [
          last_value("mana.queue.observation.success", event_name: event, measurement: :success),
          last_value("mana.queue.observation.timestamp.seconds", event_name: event, measurement: :timestamp),
          last_value("mana.queue.oldest.due.age.seconds", event_name: event ++ [:queue],
            measurement: :age, tags: [:queue], keep: &(Map.get(&1, :queue) in queues)),
          last_value("mana.queue.discarded.present", event_name: event ++ [:queue],
            measurement: :discarded, tags: [:queue], keep: &(Map.get(&1, :queue) in queues))
        ]
    end
  end

  defp duration(name, options),
    do: distribution(name, options ++ [unit: {:native, :microsecond}])

  defp http?(metadata, endpoint) do
    # Both the normal endpoint and Phoenix's development reload wrapper are
    # scoped to this endpoint. A second Bandit server is not silently included.
    matches = case Map.get(metadata, :plug) do
      {^endpoint, _} -> true
      {Phoenix.Endpoint.SyncCodeReloadPlug, {^endpoint, _}} -> true
      _ -> false
    end
    matches and get_in(metadata, [:conn, Access.key(:request_path)]) != "/metrics"
  end

  defp http_tags(metadata) do
    conn = Map.get(metadata, :conn)
    method = if conn, do: conn.method, else: nil
    status = if conn, do: conn.status, else: nil
    %{method: if(method in ~w(GET POST PUT PATCH DELETE HEAD OPTIONS CONNECT TRACE), do: method, else: "OTHER"),
      status_class: if(is_integer(status) and status in 100..599, do: "#{div(status, 100)}xx", else: "unknown")}
  end

  defp query_tags(%{result: {:ok, _}}), do: %{result: "ok"}
  defp query_tags(%{result: {:error, _}}), do: %{result: "error"}
  defp query_tags(_), do: %{result: "unknown"}

  defp queue(metadata, queues) do
    value = get_in(metadata, [:job, Access.key(:queue)])
    if value in queues, do: value, else: "other"
  end
end
