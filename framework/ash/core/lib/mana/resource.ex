defmodule Mana.Resource.Public do
  @moduledoc false
  defstruct [:action, :rate_limit, :reason, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Resource.Limit do
  @moduledoc false
  defstruct [:action, :rate_limit, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Resource.Retention do
  @moduledoc false
  defstruct [:field, :days, :action, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Resource do
  @moduledoc """
  Transport-facing decisions about a resource's actions.

      access do
        public :register, rate_limit: "10 per minute per ip"
        public :log_out, rate_limit: :none, reason: "only burns the presented token"
        limit :change_password, "5 per minute per actor"
      end

  `public` actions are reachable without a session (policies still decide what they
  do). Every public action must make a rate-limit decision; opting out requires a
  reason. Limits are enforced by the action itself, whatever the transport, using the
  Hammer module configured as `config :mana_core, limiter: MyApp.Limits`; set
  `rate_limits?: false` to disable them (e.g. outside production).
  """
  @public %Spark.Dsl.Entity{
    name: :public,
    target: Mana.Resource.Public,
    args: [:action],
    identifier: :action,
    schema: [
      action: [type: :atom, required: true],
      rate_limit: [type: {:or, [:string, {:in, [:none]}]}, required: true],
      reason: [type: :string]
    ]
  }

  @limit %Spark.Dsl.Entity{
    name: :limit,
    target: Mana.Resource.Limit,
    args: [:action, :rate_limit],
    identifier: :action,
    schema: [action: [type: :atom, required: true], rate_limit: [type: :string, required: true]]
  }

  @access %Spark.Dsl.Section{name: :access, entities: [@public, @limit]}

  @delete_after %Spark.Dsl.Entity{
    name: :delete_after,
    target: Mana.Resource.Retention,
    args: [:field],
    schema: [
      field: [type: :atom, required: true, doc: "A datetime attribute; rows past it by `days` are deleted."],
      days: [type: :non_neg_integer, required: true, doc: "`0` deletes once the moment itself has passed."],
      action: [type: :atom, default: :destroy]
    ]
  }

  @retention %Spark.Dsl.Section{
    name: :retention,
    describe: "How long rows are kept. `Mana.Retention.Worker` deletes them on schedule.",
    entities: [@delete_after]
  }

  @privacy %Spark.Dsl.Section{
    name: :privacy,
    describe: """
    Whose personal data the rows are, and what the data-subject rights do with them
    (`Mana.Privacy.export/2`, `Mana.Privacy.erase/2`):

        privacy do
          subject :traveler_id
          export [:plate, :vehicle, :created_at]
          erase :delete
        end

    `export` is an explicit projection, never the raw row. `erase :keep` (a lawful
    basis to retain) requires a `reason`. `erase :detach` keeps rows that other
    records still name (a place a booking was at) but cuts them from the person
    through the resource's `detach` update action (clearing the subject and
    whatever else identifies them); it requires a `reason` too.
    """,
    schema: [
      subject: [type: :atom, doc: "The attribute holding the person's user id."],
      export: [type: {:list, :atom}, default: []],
      erase: [type: {:in, [:delete, :keep, :detach]}],
      reason: [type: :string]
    ]
  }

  # Checks run in a transformer, not a verifier: Spark reports verifier failures as
  # warnings, and these must fail compilation.
  use Spark.Dsl.Extension, sections: [@access, @retention, @privacy], transformers: [Mana.Resource.Transformer]

  @doc "Parses `\"N per second|minute|hour|day per ip|actor\"`."
  def parse_limit(spec) when is_binary(spec) do
    case Regex.run(~r/^(\d+) per (second|minute|hour|day) per (ip|actor)$/, String.trim(spec)) do
      [_, n, unit, per] when n != "0" ->
        {:ok,
         %{count: String.to_integer(n), window: window(unit), per: String.to_existing_atom(per)}}

      _ ->
        :error
    end
  end

  defp window("second"), do: 1_000
  defp window("minute"), do: 60_000
  defp window("hour"), do: 3_600_000
  defp window("day"), do: 86_400_000
end

defmodule Mana.Resource.Info do
  @moduledoc false
  use Spark.InfoGenerator, extension: Mana.Resource, sections: [:access, :retention, :privacy]

  def public?(resource, action),
    do: Enum.any?(access(resource), &match?(%Mana.Resource.Public{action: ^action}, &1))

  def limit(resource, action) do
    case Enum.find(access(resource), &(&1.action == action)) do
      %{rate_limit: spec} when is_binary(spec) -> elem(Mana.Resource.parse_limit(spec), 1)
      _ -> nil
    end
  end
end

defmodule Mana.Resource.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: true

  def transform(dsl) do
    entries = Transformer.get_entities(dsl, [:access])
    actions = dsl |> Transformer.get_entities([:actions]) |> MapSet.new(& &1.name)

    retention = Transformer.get_entities(dsl, [:retention])
    attributes = Transformer.get_entities(dsl, [:attributes])

    problems =
      Enum.map(entries, &problem(&1, actions)) ++
        Enum.map(retention, &retention_problem(&1, actions, attributes)) ++ [privacy_problem(dsl, attributes)]

    case Enum.find(problems, & &1) do
      nil -> {:ok, add_rate_limit(dsl, Enum.any?(entries, &is_binary(&1.rate_limit)))}
      message -> {:error, Spark.Error.DslError.exception(module: Transformer.get_persisted(dsl, :module), path: [:access], message: message)}
    end
  end

  defp problem(entry, actions) do
    cond do
      entry.action not in actions ->
        "`#{entry.action}` is not an action of this resource"

      entry.rate_limit == :none and blank?(Map.get(entry, :reason)) ->
        "public `#{entry.action}` opts out of rate limiting without a `reason`"

      is_binary(entry.rate_limit) and Mana.Resource.parse_limit(entry.rate_limit) == :error ->
        "rate limit #{inspect(entry.rate_limit)} must read `N per minute per ip|actor`"

      true ->
        nil
    end
  end

  defp retention_problem(rule, actions, attributes) do
    attribute = Enum.find(attributes, &(&1.name == rule.field))

    cond do
      is_nil(attribute) or base_type(attribute.type) not in [Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime, Ash.Type.DateTime] ->
        "retention field `#{rule.field}` must be a datetime attribute"

      rule.action not in actions ->
        "retention action `#{rule.action}` is not an action of this resource"

      true ->
        nil
    end
  end

  defp base_type(type) do
    if Ash.Type.NewType.new_type?(type), do: base_type(Ash.Type.NewType.subtype_of(type)), else: Ash.Type.get_type(type)
  end

  defp privacy_problem(dsl, attributes) do
    option = &Transformer.get_option(dsl, [:privacy], &1)
    fields = MapSet.new(attributes, & &1.name) |> MapSet.union(MapSet.new(Transformer.get_entities(dsl, [:calculations]), & &1.name))
    destroy? = dsl |> Transformer.get_entities([:actions]) |> Enum.any?(&(&1.type == :destroy and &1.primary?))
    detach? = dsl |> Transformer.get_entities([:actions]) |> Enum.any?(&(&1.type == :update and &1.name == :detach))

    cond do
      is_nil(option.(:subject)) and is_nil(option.(:erase)) -> nil
      option.(:subject) not in MapSet.new(attributes, & &1.name) -> "privacy subject `#{option.(:subject)}` must be an attribute"
      is_nil(option.(:erase)) -> "privacy must declare `erase :delete`, `erase :keep` or `erase :detach`"
      (missing = Enum.reject(option.(:export) || [], &(&1 in fields))) != [] -> "privacy export names unknown fields #{inspect(missing)}"
      option.(:erase) in [:keep, :detach] and blank?(option.(:reason)) -> "privacy `erase #{inspect(option.(:erase))}` needs the lawful `reason` to retain"
      option.(:erase) == :detach and not detach? -> "privacy `erase :detach` needs an update action `detach` that cuts the row from the person"
      option.(:erase) == :delete and not destroy? -> "privacy `erase :delete` needs a primary destroy action"
      true -> nil
    end
  end

  defp add_rate_limit(dsl, false), do: dsl

  defp add_rate_limit(dsl, true) do
    {:ok, validation} =
      Transformer.build_entity(Ash.Resource.Dsl, [:validations], :validate,
        validation: {Mana.RateLimit, []},
        on: [:create, :update, :destroy, :action]
      )

    Transformer.add_entity(dsl, [:validations], validation, type: :append)
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end

defmodule Mana.RateLimit do
  @moduledoc "Counts calls of rate-limited actions. Keys never contain request bodies."
  use Ash.Resource.Validation

  @impl true
  def supports(_), do: [Ash.Changeset, Ash.ActionInput]

  @impl true
  def validate(subject, _opts, context) do
    with true <- Application.get_env(:mana_core, :rate_limits?, true),
         %{} = limit <- Mana.Resource.Info.limit(subject.resource, subject.action.name) do
      key = {subject.resource, subject.action.name, subject_key(limit.per, context)}
      limiter = Application.fetch_env!(:mana_core, :limiter)

      case limiter.hit(key, limit.window, limit.count) do
        {:allow, _} ->
          :ok

        {:deny, ms} ->
          {:error,
           Mana.Error.new("platform.rate_limited", "too many requests",
             status: 429,
             meta: %{retry_after: max(1, div(ms + 999, 1000))}
           )}
      end
    else
      _ -> :ok
    end
  end

  @impl true
  def atomic(subject, opts, context), do: validate(subject, opts, context)

  defp subject_key(:ip, context), do: get_in(context.source_context, [:mana, :ip]) || :unknown
  defp subject_key(:actor, %{actor: %{id: id}}), do: id
  defp subject_key(:actor, _), do: :anonymous
end

defmodule Mana.Router do
  @moduledoc "Derives transport facts from the resources' `access` declarations."

  @doc "The `{method, path_info}` patterns of public AshJsonApi routes under `prefix`."
  def public_routes(domains, prefix) do
    prefix = String.split(prefix, "/", trim: true)

    for domain <- domains,
        route <- AshJsonApi.Domain.Info.routes(domain),
        Mana.Resource.Info.public?(route.resource, route.action) do
      {route.method |> to_string() |> String.upcase(),
       prefix ++ String.split(route.route, "/", trim: true)}
    end
  end

  @doc "Whether `conn`'s method and path match one of the given patterns (`:param` segments match any)."
  def match?(%{method: method, path_info: path}, patterns) do
    Enum.any?(patterns, fn {m, pattern} ->
      m == method and length(pattern) == length(path) and
        Enum.all?(Enum.zip(pattern, path), fn {p, s} -> String.starts_with?(p, ":") or p == s end)
    end)
  end
end
