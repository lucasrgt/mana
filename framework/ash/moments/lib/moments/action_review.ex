defmodule Moments.ActionReview do
  @moduledoc "Local review planning from compiled Ash metadata; never executes an action or approves it."
  alias Ash.Resource.Info

  def build(resource, name) when is_binary(name) do
    unless Info.resource?(resource), do: raise(ArgumentError, "Expected a compiled Ash resource")

    action = Enum.find(Info.actions(resource), &(Atom.to_string(&1.name) == name))
    unless action, do: raise(ArgumentError, "Unknown action on the selected resource")

    domain = Info.domain(resource)
    layer = Info.data_layer(resource)
    authorizers = Info.authorizers(resource)
    manual = !is_nil(Map.get(action, :manual)) or Map.get(action, :manual?, false)
    write = action.type in [:create, :update, :destroy]
    hooks = hooks(resource, action)
    notifiers = Info.notifiers(resource)
    jobs = jobs(resource, action)

    questions = [
      question(
        "authorization",
        "Action entry point",
        "Follow actor, tenant and authorize? through actual callers; exercise denied and cross-owner paths. Configured authorizers alone do not prove enforcement."
      )
    ]

    questions =
      if layer not in [nil, Ash.DataLayer.Simple] and action.type != :action do
        questions ++
          [
            question(
              "persistence",
              "Configured data layer: #{inspect(layer)}",
              "Inspect actual Repo/pool ownership and custom hooks for serialization, unbounded queries and N+1. Measure contention when the change affects it."
            )
          ]
      else
        questions
      end

    questions =
      if write or Map.get(action, :transaction?, false) do
        questions ++
          [
            question(
              "transactions",
              "#{action.type} action; transaction?=#{Map.get(action, :transaction?, false)}",
              "Check the business invariant against database constraints, locking, nested calls and rollback behavior. A transaction flag does not prove concurrency safety or roll back remote effects."
            )
          ]
      else
        questions
      end

    questions =
      if manual or hooks != [] or notifiers != [] or action.type == :action do
        questions ++
          [
            question(
              "custom-execution",
              "Declared hooks, manual implementation or notifiers",
              "Inspect the listed implementations and their callbacks for external effects, jobs, retries, global processes and authorization bypasses; select additional Moments from those actual dependencies."
            )
          ]
      else
        questions
      end

    questions =
      if jobs != [] do
        questions ++
          [
            question(
              "jobs",
              "AshOban declares references to this action",
              "Review actor/tenant restoration, retry and idempotency, queue ownership and failure handling for the listed triggers. Database commit does not guarantee exactly-once external delivery."
            )
          ]
      else
        questions
      end

    %{
      version: 1,
      status: "planned",
      executed: false,
      verification: "not-performed",
      target: %{
        resource: inspect(resource),
        action: name,
        type: to_string(action.type),
        domain: module_name(domain)
      },
      facts: %{
        data_layer: module_name(layer),
        authorizers: Enum.map(authorizers, &inspect/1),
        multitenancy: Info.multitenancy_strategy(resource),
        action_multitenancy: Map.get(action, :multitenancy),
        transaction_declared: Map.get(action, :transaction?, false),
        manual: manual,
        hooks: hooks,
        notifiers: Enum.map(notifiers, &inspect/1),
        touches_resources: Enum.map(Map.get(action, :touches_resources, []), &inspect/1),
        jobs: jobs
      },
      properties: defaults(layer, authorizers, manual or action.type == :action),
      reviews: questions,
      moments: candidates(domain),
      unknowns: [
        "Inbound callers, authorize? overrides and tenant propagation are not resolved by this plan.",
        "Hook options, function bodies, callbacks and dynamic dispatch are not analyzed; effect inventory is incomplete.",
        "Jobs created in custom code or other resources are not inferred from local AshOban declarations.",
        "Moment candidates share the resource's primary domain; action execution and assertion coverage are not established.",
        "Runtime load, query counts, transaction isolation and external delivery behavior have not been measured."
      ]
    }
  end

  defp question(id, reason, text),
    do: %{id: id, level: "reviewed", status: "pending", reason: reason, question: text}

  defp defaults(layer, authorizers, manual) do
    persistence =
      if layer == AshPostgres.DataLayer and !manual do
        [
          %{
            property: "persistence-path",
            level: "default-safe",
            mechanism: "AshPostgres.DataLayer",
            boundary: "Standard execution of the selected non-manual action",
            bypasses: ["Custom hooks", "Direct Repo/SQL", "Other entry points"],
            evidence: "compiled-configuration"
          }
        ]
      else
        []
      end

    if Ash.Policy.Authorizer in authorizers do
      persistence ++
        [
          %{
            property: "authorization-path",
            level: "default-safe",
            mechanism: "Ash.Policy.Authorizer",
            boundary: "Ash calls with authorization enabled",
            bypasses: ["authorize?: false", "Direct Repo/SQL", "Privileged callers"],
            evidence: "compiled-configuration"
          }
        ]
    else
      persistence
    end
  end

  defp hooks(resource, action) do
    changes = Info.action_changes(resource, action)

    validations =
      if Map.get(action, :skip_global_validations?, false),
        do: [],
        else: Info.validations(resource, action.type)

    preparations =
      if action.type in [:read, :action] do
        Info.preparations(resource, action.type) ++ Map.get(action, :preparations, [])
      else
        []
      end

    (Enum.flat_map(changes ++ validations ++ preparations, fn entry ->
       for key <- [:change, :validation, :preparation],
           value = Map.get(entry, key),
           !is_nil(value),
           do: %{kind: to_string(key), implementation: implementation(value)}
     end) ++
       for(
         key <- [:manual, :run, :error_handler, :modify_query],
         value = Map.get(action, key),
         !is_nil(value),
         do: %{kind: to_string(key), implementation: implementation(value)}
       ))
    |> Enum.uniq()
  end

  # Never serialize options, anonymous function environments, descriptions or input values.
  defp implementation({module, _options}) when is_atom(module), do: inspect(module)

  defp implementation({module, function, _arity}) when is_atom(module) and is_atom(function),
    do: "#{inspect(module)}.#{function}"

  defp implementation(module) when is_atom(module), do: inspect(module)
  defp implementation(_), do: "opaque"
  defp module_name(nil), do: nil
  defp module_name(module), do: inspect(module)

  defp jobs(resource, action) do
    if AshOban in Spark.extensions(resource) do
      unless Code.ensure_loaded?(AshOban.Info) and
               function_exported?(AshOban.Info, :oban_triggers_and_scheduled_actions, 1),
             do: raise(ArgumentError, "Installed AshOban introspection is unsupported")

      # AshOban is optional; rely on its native Info API when the resource uses it.
      apply(AshOban.Info, :oban_triggers_and_scheduled_actions, [resource])
      |> Enum.flat_map(fn trigger ->
        for role <- [:action, :read_action, :worker_read_action, :on_error],
            Map.get(trigger, role) == action.name do
          %{
            name: to_string(trigger.name),
            kind: inspect(trigger.__struct__),
            role: to_string(role),
            worker: module_name(Map.get(trigger, :worker_module_name))
          }
        end
      end)
      |> Enum.sort_by(&{&1.name, &1.role})
    else
      []
    end
  end

  defp candidates(nil), do: []

  defp candidates(domain) do
    if Moments.Extension in Spark.extensions(domain) do
      Spark.Dsl.Extension.get_entities(domain, [:moments])
      |> Enum.filter(&is_struct(&1, Moments.Scene))
      |> Enum.map(fn scene ->
        %{
          name: scene.name |> to_string() |> String.replace("_", "-"),
          relation: "same-primary-domain",
          coverage: "unverified"
        }
      end)
      |> Enum.sort_by(& &1.name)
    else
      []
    end
  end
end
