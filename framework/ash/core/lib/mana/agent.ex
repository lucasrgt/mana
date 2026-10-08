defmodule Mana.Agent do
  @moduledoc """
  Agents act on an app the way its screens do, not through a flat list of
  endpoints: `open/4` an entry (a `Mana.Views` view declared with
  `entry: :read_action`) and get its records in that view with the verbs each
  offers the actor now and their inputs; `follow/6` one of those verbs and
  get the record back with what it offers next. A verb the record does not
  offer cannot be followed, so an agent never does what the interface would
  not let the person do. Follows run with `mana_agent:` in the action
  context, so `Mana.History` records them as the agent's. `Mana.Agent.Plug`
  serves both over HTTP; `mana agent mcp` bridges them to MCP.
  """

  @page 20

  @doc "The entries agents may open, across `domains`."
  def entries(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        Mana.Views in Spark.extensions(resource),
        view <- Mana.Views.declared(resource),
        view.entry do
      %{name: "#{Mana.Entity.type(resource)}.#{view.name}", resource: resource, view: view, describe: view.describe}
    end
  end

  @doc "The records of entry `name` the actor may read, in its view."
  def open(domains, name, actor, opts \\ []) do
    case Enum.find(entries(domains), &(&1.name == name)) do
      nil ->
        {:error, %{reason: "no_such_entry", entries: Enum.map(entries(domains), & &1.name)}}

      %{resource: resource, view: view} ->
        records =
          resource
          |> Ash.Query.for_read(view.entry, Keyword.get(opts, :arguments, %{}), actor: actor)
          |> Ash.Query.load(Mana.Views.loads(resource, view.name) ++ verbs_load(resource))
          |> Ash.Query.limit(@page + 1)
          |> Ash.read!()

        {:ok, %{entry: name, records: Enum.map(Enum.take(records, @page), &describe(&1, view, actor)), more: length(records) > @page}}
    end
  end

  @doc "The record-less collection verbs the actor may start now (`Mana.Verbs.available/2`)."
  def available(domains, actor), do: Mana.Verbs.available(domains, actor)

  @doc """
  Performs the collection verb `qualified` (`"type.verb"`) with `params`
  when it is available to the actor; answers what it created or returned.
  """
  def start(domains, qualified, params, actor, opts \\ []) do
    with [type, name] <- String.split(qualified, ".", parts: 2) |> then(&if(length(&1) == 2, do: &1, else: [nil, nil])),
         {:ok, resource} <- resource(domains, type),
         %{} = verb <- Enum.find(Mana.Verbs.declared(resource), &(&1.collection and to_string(&1.name) == name)) || {:error, %{reason: "not_offered"}},
         true <- verb.from != nil or qualified in Mana.Verbs.available(domains, actor) || {:error, %{reason: "not_offered"}} do
      context = %{mana_agent: Keyword.get(opts, :agent, "agent")}
      action = Ash.Resource.Info.action(resource, Mana.Verbs.action(verb))

      result =
        case action.type do
          :create -> resource |> Ash.Changeset.for_create(action.name, params, actor: actor, context: context) |> Ash.create()
          :action -> resource |> Ash.ActionInput.for_action(action.name, params, actor: actor, context: context) |> Ash.run_action()
        end

      case refused(result) do
        {:ok, %{__struct__: _} = record} -> {:ok, %{type: type, id: Map.get(record, :id)}}
        {:ok, value} -> {:ok, %{type: type, result: Mana.History.encode(value)}}
        error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, %{reason: "not_offered"}}
    end
  end

  @doc "Performs `verb` on the `type` record `id` when it offers it; answers the record after."
  def follow(domains, type, id, verb, params, actor, opts \\ [])

  def follow(domains, type, id, verb, params, actor, opts) when is_binary(verb) do
    if String.contains?(verb, "."), do: follow_child(domains, type, id, verb, params, actor, opts), else: follow_own(domains, type, id, verb, params, actor, opts)
  end

  # A parent's collection verb: performed on the child resource, its `from`
  # field set to the parent.
  defp follow_child(domains, type, id, qualified, params, actor, opts) do
    with {:ok, resource} <- resource(domains, type),
         {:ok, record} <- fetch(resource, id, actor),
         offered = Mana.Verbs.offered(record, actor),
         true <- qualified in offered || {:error, %{reason: "not_offered", offered: offered}},
         [child_type, name] = String.split(qualified, ".", parts: 2),
         {:ok, child} <- resource(domains, child_type),
         %{from: {_, field}} <- Enum.find(Mana.Verbs.declared(child), &(to_string(&1.name) == name)) do
      start(domains, qualified, Map.put(params, to_string(field), id), actor, opts)
    end
  end

  defp follow_own(domains, type, id, verb, params, actor, opts) do
    with {:ok, resource} <- resource(domains, type),
         {:ok, record} <- fetch(resource, id, actor),
         offered = Mana.Verbs.offered(record, actor),
         true <- verb in offered || {:error, %{reason: "not_offered", offered: offered}},
         declared = Enum.find(Mana.Verbs.declared(resource), &(to_string(&1.name) == verb)),
         {:ok, updated} <-
           record
           |> Ash.Changeset.for_update(Mana.Verbs.action(declared), params, actor: actor, context: %{mana_agent: Keyword.get(opts, :agent, "agent")})
           |> Ash.update()
           |> refused() do
      view = Mana.Views in Spark.extensions(resource) && List.first(Mana.Views.declared(resource))
      updated = Ash.load!(updated, if(view, do: Mana.Views.loads(resource, view.name), else: []) ++ verbs_load(resource), actor: actor)
      {:ok, describe(updated, view, actor)}
    end
  end

  defp resource(domains, type) do
    found =
      for domain <- domains, resource <- Ash.Domain.Info.resources(domain), Mana.Verbs in Spark.extensions(resource), Mana.Entity.type(resource) == type, do: resource

    case found do
      [resource | _] -> {:ok, resource}
      [] -> {:error, %{reason: "no_such_type"}}
    end
  end

  defp fetch(resource, id, actor) do
    case Ash.get(resource, id, actor: actor) do
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:error, %{reason: "not_found"}}
    end
  end

  defp refused({:ok, _} = ok), do: ok

  defp refused({:error, error}) do
    fields =
      for e <- Map.get(error, :errors, [error]), field = Map.get(e, :field), into: %{}, do: {to_string(field), Mana.History.error_code(e)}

    {:error, %{reason: "refused", code: Mana.History.error_code(error), fields: fields}}
  end

  defp verbs_load(resource), do: if(Mana.Verbs in Spark.extensions(resource), do: [Mana.Verbs.calculation(resource)], else: [])

  defp describe(record, view, actor) do
    resource = record.__struct__
    offered = Mana.Verbs.offered(record, actor)
    own = Map.new(Mana.Verbs.contract(resource), &{&1["name"], &1})

    contract =
      for {child, verb} <- Mana.Verbs.children(resource),
          entry <- Mana.Verbs.contract(child),
          entry["name"] == to_string(verb.name),
          into: own,
          do: {"#{Mana.Entity.type(child)}.#{verb.name}", Map.put(entry, "name", "#{Mana.Entity.type(child)}.#{verb.name}")}
    fields = if view, do: view.fields -- [:verbs], else: []

    %{
      type: Mana.Entity.type(resource),
      id: record.id,
      fields: Map.new(fields, &{to_string(&1), Mana.History.encode(Map.get(record, &1))}),
      verbs: for(name <- offered, do: Map.take(contract[name], ["name", "risk", "describe", "inputs", "inverse"]))
    }
  end
end

if Code.ensure_loaded?(Plug.Conn) do
  defmodule Mana.Agent.Plug do
    @moduledoc """
    `POST {"tool": "entries" | "open" | "follow" | "available" | "start", ...}`
    as the signed-in actor: `open` takes `entry` (and `arguments`), `follow`
    takes `type`, `id`, `verb` (its own, or a child's `type.verb`) and
    `params`, `available` lists the record-less verbs the actor may start,
    and `start` takes `verb` (`type.verb`) and `params`. Mount behind the app's authentication:
    `forward "/agent", Mana.Agent.Plug, domains: [...]`. The `x-mana-agent`
    header names the agent in the history.
    """
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      domains = Keyword.fetch!(opts, :domains)
      actor = Ash.PlugHelpers.get_actor(conn)
      {request, conn} = request(conn)
      agent = conn |> get_req_header("x-mana-agent") |> List.first() || "agent"

      result =
        case request do
          {:ok, %{"tool" => "entries"}} -> {:ok, %{entries: for(e <- Mana.Agent.entries(domains), do: %{name: e.name, describe: e.describe})}}
          {:ok, %{"tool" => "open", "entry" => entry} = call} -> Mana.Agent.open(domains, entry, actor, arguments: call["arguments"] || %{})
          {:ok, %{"tool" => "follow"} = c} -> Mana.Agent.follow(domains, c["type"], c["id"], c["verb"], c["params"] || %{}, actor, agent: agent)
          {:ok, %{"tool" => "available"}} -> {:ok, %{available: Mana.Agent.available(domains, actor)}}
          {:ok, %{"tool" => "start", "verb" => verb} = c} -> Mana.Agent.start(domains, verb, c["params"] || %{}, actor, agent: agent)
          _ -> {:error, %{reason: "bad_request"}}
        end

      {status, payload} =
        case result do
          {:ok, value} -> {200, value}
          {:error, %{reason: "bad_request"} = e} -> {400, e}
          {:error, %{reason: reason} = e} when reason in ["not_found", "no_such_type", "no_such_entry"] -> {404, e}
          {:error, e} -> {422, e}
        end

      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(payload)) |> halt()
    end

    # An endpoint's Plug.Parsers may have read the body already.
    defp request(%{body_params: %{} = params} = conn) when map_size(params) > 0, do: {{:ok, params}, conn}

    defp request(conn) do
      {:ok, body, conn} = read_body(conn, length: 1_000_000)
      {Jason.decode(body), conn}
    end
  end
end
