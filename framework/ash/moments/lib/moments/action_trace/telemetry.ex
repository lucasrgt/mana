defmodule Moments.ActionTrace.Telemetry do
  @moduledoc "Supervised registration of native Ash bulk telemetry; handlers run in the emitting process."
  use GenServer

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    id = {__MODULE__, Keyword.fetch!(options, :id)}
    domains = Keyword.fetch!(options, :domains)

    candidates =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          do:
            {{Ash.Domain.Info.short_name(domain), Ash.Resource.Info.short_name(resource)},
             {domain, resource}}

    # Short names are telemetry labels, not globally unique resource identities.
    # Ambiguous mappings cannot authorize an attribution.
    mapping =
      candidates
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {key, values} -> {key, if(length(values) == 1, do: hd(values))} end)

    events =
      for domain <- domains,
          kind <- [:bulk_create, :bulk_update, :bulk_destroy],
          do: [:ash, Ash.Domain.Info.short_name(domain), kind, :stop]

    :telemetry.detach(id)
    :ok = :telemetry.attach_many(id, Enum.uniq(events), &__MODULE__.handle_event/4, mapping)
    query_id = {id, :queries}
    :telemetry.detach(query_id)
    if event = Keyword.get(options, :repo_event),
      do: :ok = :telemetry.attach(query_id, event, &__MODULE__.handle_query/4, nil)
    {:ok, {id, query_id}}
  end

  @impl true
  def terminate(_reason, {id, query_id}) do
    :telemetry.detach(id)
    :telemetry.detach(query_id)
  end

  def handle_query(_event, measurements, _metadata, _config),
    do: Moments.ActionTrace.observe_query(measurements)

  def handle_event([:ash, domain_name, kind, :stop], measurements, metadata, mapping) do
    if Moments.ActionTrace.get_span_context() do
      case Map.get(mapping, {domain_name, metadata[:resource_short_name]}) do
        {domain, resource} ->
          action = metadata[:action]

          if is_atom(action) and !is_nil(action) and Ash.Resource.Info.action(resource, action),
            do: Moments.ActionTrace.observe_bulk(kind, domain, resource, action, measurements[:duration])

        _ ->
          :ok
      end
    end

    :ok
  end
end
