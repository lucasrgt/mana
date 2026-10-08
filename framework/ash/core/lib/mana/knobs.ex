defmodule Mana.Knobs do
  @moduledoc """
  Values that change while the app runs, often by someone who is not a
  developer, declared in code and stored only as their current value:

      defmodule MyApp.Knobs do
        use Mana.Knobs, store: MyApp.Platform.KnobValue

        knob :coupons_enabled, :boolean, default: false, feature: "checkout/coupon", describe: "Coupons at checkout"
        knob :trial_months, :integer, default: {MyApp.Billing, :configured, [:trial_months]}
      end

  `get/1` answers the stored value, or the default (a value or an MFA, so a
  config or environment value stays the fallback) until someone sets one;
  `set/3` stores it with who changed it — give the store `Mana.History` to
  keep every change. A boolean knob may roll out gradually:
  `set(:coupons_enabled, %{"value" => false, "actors" => [id], "percent" => 10}, by)`
  makes `enabled?/2` true for those actors and a stable 10% of the rest. A
  number knob may declare `min:` and `max:`; `set/3` refuses a value outside
  them. A verb declared with `knob: :coupons_enabled` (`Mana.Verbs`) is offered and
  allowed only while the knob is on for the actor, so turning it off blocks
  the server, not just the screen. `stale/1` lists knobs nobody changed for
  months — candidates to remove with the code they guard. Ask "does someone
  who is not a developer need to change this while the app runs?"; if not, it
  is configuration, not a knob.
  """

  defmacro __using__(opts) do
    quote do
      import Mana.Knobs, only: [knob: 2, knob: 3]
      Module.register_attribute(__MODULE__, :mana_knobs, accumulate: true)
      @mana_knob_store unquote(Keyword.fetch!(opts, :store))
      @before_compile Mana.Knobs
    end
  end

  @types [:boolean, :integer, :string, :float]

  defmacro knob(name, type, opts \\ []) do
    unless type in @types, do: raise(ArgumentError, "knob #{inspect(name)} has type #{inspect(type)}; use one of #{inspect(@types)}")

    quote do
      @mana_knobs %{name: unquote(name), type: unquote(type), opts: unquote(opts)}
    end
  end

  defmacro __before_compile__(env) do
    knobs = env.module |> Module.get_attribute(:mana_knobs) |> Enum.reverse()
    store = Module.get_attribute(env.module, :mana_knob_store)

    quote do
      def __knobs__, do: unquote(Macro.escape(knobs))
      def __knob_store__, do: unquote(store)
      def knobs, do: Mana.Knobs.declared(__MODULE__)
      def get(name), do: Mana.Knobs.get(__MODULE__, name)
      def enabled?(name, actor \\ nil), do: Mana.Knobs.enabled?(__MODULE__, name, actor)
      def set(name, value, by), do: Mana.Knobs.set(__MODULE__, name, value, by)
      def unset(name), do: Mana.Knobs.unset(__MODULE__, name)
      def stale(opts \\ []), do: Mana.Knobs.stale(__MODULE__, opts)
    end
  end

  @doc "The declared knobs with their current value."
  def declared(module) do
    for knob <- module.__knobs__() do
      %{name: knob.name, type: knob.type, feature: knob.opts[:feature], describe: knob.opts[:describe], min: knob.opts[:min], max: knob.opts[:max], value: get(module, knob.name)}
    end
  end

  defp knob!(module, name),
    do: Enum.find(module.__knobs__(), &(&1.name == name)) || raise(ArgumentError, "#{inspect(module)} declares no knob #{inspect(name)}")

  # Read from the store at most every `knob_ttl_ms` (5 s) per node, so a
  # change made on one machine reaches the others without a broadcast.
  defp stored(module, name) do
    key = {__MODULE__, module, name}
    now = System.monotonic_time(:millisecond)
    ttl = Application.get_env(:mana_core, :knob_ttl_ms, 5_000)

    case :persistent_term.get(key, :unset) do
      {value, at} when now - at < ttl ->
        value

      _ ->
        value =
          case Ash.get(module.__knob_store__(), to_string(name), authorize?: false, error?: false) do
            {:ok, %{value: value}} when is_map(value) -> value
            _ -> nil
          end

        :persistent_term.put(key, {value, now})
        value
    end
  end

  @doc "The knob's value: the stored one, or its default."
  def get(module, name) do
    knob = knob!(module, name)

    case stored(module, name) do
      %{"value" => value} -> value
      _ -> default(knob.opts[:default])
    end
  end

  defp default({m, f, a}), do: apply(m, f, a)
  defp default(value), do: value

  @doc "Whether a boolean knob is on for `actor`: its value, the listed actors, or its rollout percent."
  def enabled?(module, name, actor \\ nil) do
    id = actor && Map.get(actor, :id) && to_string(actor.id)
    rollout = stored(module, name) || %{}

    get(module, name) == true or
      (id != nil and id in (rollout["actors"] || [])) or
      (id != nil and is_integer(rollout["percent"]) and :erlang.phash2({name, id}, 100) < rollout["percent"])
  end

  @doc "Stores `value` (or `%{\"value\" => v, \"actors\" => [...], \"percent\" => n}`) as changed by `by`."
  def set(module, name, value, by) do
    knob = knob!(module, name)
    value = if is_map(value), do: value, else: %{"value" => value}

    with :ok <- typed(knob.type, value["value"]),
         :ok <- within(knob.opts, value["value"]) do
      result =
        module.__knob_store__()
        |> Ash.Changeset.for_create(:set, %{name: to_string(name), value: value, changed_by_id: by && Map.get(by, :id)}, actor: by)
        |> Ash.create(authorize?: false)

      :persistent_term.erase({__MODULE__, module, name})
      result
    end
  end

  @doc "Forgets the stored value: the knob answers its default again."
  def unset(module, name) do
    knob!(module, name)

    with {:ok, row} when not is_nil(row) <- Ash.get(module.__knob_store__(), to_string(name), authorize?: false, error?: false),
         do: Ash.destroy!(row, authorize?: false)

    :persistent_term.erase({__MODULE__, module, name})
    :ok
  end

  defp typed(:boolean, value) when is_boolean(value), do: :ok
  defp typed(:integer, value) when is_integer(value), do: :ok
  defp typed(:float, value) when is_number(value), do: :ok
  defp typed(:string, value) when is_binary(value), do: :ok
  defp typed(type, value), do: {:error, "a #{type} knob cannot hold #{inspect(value)}"}

  defp within(opts, value) when is_number(value) do
    cond do
      opts[:min] && value < opts[:min] -> {:error, "must be at least #{opts[:min]}"}
      opts[:max] && value > opts[:max] -> {:error, "must be at most #{opts[:max]}"}
      true -> :ok
    end
  end

  defp within(_opts, _value), do: :ok

  @doc "Knobs never set, or last changed more than `days` (90) ago."
  def stale(module, opts \\ []) do
    cutoff = DateTime.add(DateTime.utc_now(), -Keyword.get(opts, :days, 90), :day)
    rows = Map.new(Ash.read!(module.__knob_store__(), authorize?: false), &{&1.name, &1})

    for knob <- module.__knobs__(), stale?(rows[to_string(knob.name)], cutoff), do: knob.name
  end

  defp stale?(nil, _cutoff), do: true
  defp stale?(row, cutoff), do: DateTime.compare(row.updated_at, cutoff) == :lt
end

defmodule Mana.Knobs.Store do
  @moduledoc """
  Makes a resource the store of a `Mana.Knobs` module: one row per knob that
  was set (`name`, `value`, `changed_by_id`, timestamps) and the upsert
  action `set`.
  """
  use Spark.Dsl.Extension, transformers: [Mana.Knobs.Store.Transformer]
end

defmodule Mana.Knobs.Store.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder

  def before?(_), do: true

  def transform(dsl) do
    with {:ok, dsl} <- Builder.add_new_attribute(dsl, :name, :string, primary_key?: true, allow_nil?: false, public?: true, writable?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :value, :map, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :changed_by_id, :uuid, public?: true),
         {:ok, dsl} <- Builder.add_new_create_timestamp(dsl, :inserted_at, type: :utc_datetime_usec),
         {:ok, dsl} <- Builder.add_new_update_timestamp(dsl, :updated_at, type: :utc_datetime_usec, public?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :read, :read, primary?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :destroy, :destroy, primary?: true) do
      Builder.add_new_action(dsl, :create, :set, accept: [:name, :value, :changed_by_id], upsert?: true, upsert_fields: [:value, :changed_by_id, :updated_at])
    end
  end
end
