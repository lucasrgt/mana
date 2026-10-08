defmodule Mana.Examples do
  @moduledoc """
  Live examples: what a function received and returned in each real
  situation, kept next to it instead of written by hand.

      use Mana.Examples

      defexample price(lines, opening, services) do
        ...
      end

  `defexample` defines the function as `def` would; in development an
  `fn:` intervention (`Mana.Intervene.Rules`) can make it raise or answer a
  given value instead. When
  `config :mana_core, :examples, dir: "<private dir>"` is set (development
  only), each call made inside a traced Moments request appends one line —
  the gesture, the arguments and the result, shortened with `inspect` — to
  `<dir>/<Module>.<fun>.jsonl` (the last 500 kept). Outside a Moments request,
  or without the config, nothing is recorded and the cost is one check.
  `mana examples <Module.fun>` shows them per Moment, newest first, and marks
  what changed since the previous run — edit the rule, rerun the affected
  Moments (`moments suite --affected --headless`) and read the difference.
  Arguments may hold real data: keep the directory private.
  """

  defmacro __using__(_opts) do
    quote do
      import Mana.Examples, only: [defexample: 2]
    end
  end

  defmacro defexample(head, do: body) do
    {name, args} = Macro.decompose_call(head)
    arity = length(args)
    vars = for {arg, index} <- Enum.with_index(args), do: binding_of(arg, index)

    quote do
      def unquote(name)(unquote_splicing(vars)) do
        result =
          case Mana.Intervene.Rules.override(__MODULE__, unquote(name)) do
            :raise -> raise "intervention: #{inspect(__MODULE__)}.#{unquote(name)} raised"
            {:return, value} -> value
            :none -> (fn unquote_splicing(args) -> unquote(body) end).(unquote_splicing(vars))
          end

        Mana.Examples.record(__MODULE__, unquote(name), unquote(arity), [unquote_splicing(vars)], result)
        result
      end
    end
  end

  defp binding_of({name, _, context}, _index) when is_atom(name) and is_atom(context), do: Macro.var(name, context)
  defp binding_of(_pattern, index), do: Macro.var(:"example_arg_#{index}", __MODULE__)

  @keep 500

  @doc false
  def record(module, name, arity, args, result) do
    with dir when is_binary(dir) <- Application.get_env(:mana_core, :examples, [])[:dir],
         gesture when is_binary(gesture) <- gesture() do
      file = Path.join(dir, "#{inspect(module)}.#{name}.jsonl")
      File.mkdir_p!(dir)

      line =
        Jason.encode!(%{
          "function" => "#{inspect(module)}.#{name}/#{arity}",
          "gesture" => gesture,
          "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "args" => Enum.map(args, &describe/1),
          "result" => describe(result)
        })

      lines = if File.exists?(file), do: file |> File.read!() |> String.split("\n", trim: true), else: []
      File.write!(file, Enum.join(Enum.take(lines ++ [line], -@keep), "\n") <> "\n")
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "A value as an example shows it: structs by name and the fields that hold something, shortened."
  def describe(value), do: value |> compact() |> inspect(limit: 12, printable_limit: 160, pretty: false) |> String.slice(0, 400)

  # A struct reads as its name and the fields that hold something.
  defp compact(%module{} = struct) when module not in [DateTime, Date, NaiveDateTime, Time, Decimal] do
    fields = struct |> Map.from_struct() |> Map.drop([:__meta__, :__metadata__, :__lateral_join_source__, :__order__, :aggregates, :calculations])
    {module |> Module.split() |> List.last(), for({k, v} <- fields, not is_nil(v) and not match?(%Ash.NotLoaded{}, v), into: %{}, do: {k, compact(v)})}
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp gesture do
    if Code.ensure_loaded?(Moments.ActionTrace) do
      case apply(Moments.ActionTrace, :get_span_context, []) do
        %{gesture: gesture} -> gesture
        _ -> nil
      end
    end
  end
end
