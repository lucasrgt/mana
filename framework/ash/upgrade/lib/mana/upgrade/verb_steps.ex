defmodule Mana.Upgrade.VerbSteps do
  @moduledoc """
  A Moments step that taps a hand-placed key becomes a step that names the
  verb, when the Flutter apps place that key on the control of a
  `VerbGate(verb: XVerbs.y, ...)`:

      step :pay, tap: "booking-pay", until: [:paid]
      # becomes
      step :pay, verb: {:booking, :pay}, until: [:paid]

  The `mapping:` option is what `mana upgrade verb-steps` scans from the apps:
  `%{"keys" => %{"booking-pay" => "booking.pay"}, "conflicts" => %{key =>
  [verb, ...]}}`. Only steps of a `moment` inside a `moments` section are
  read, so a `Mana.Flow` step is never touched. A key placed for different
  verbs, or for a verb chosen at runtime, is skipped. A verb step without
  `on:` taps the screen's first control of that verb: the keyed one, unless
  the screen draws that verb twice.
  """
  @behaviour Mana.Upgrade

  import Mana.Upgrade.Source

  @name ~r/\A[a-z_][a-z0-9_]*\z/

  @impl true
  def rewrite(sources, opts) do
    mapping = Keyword.fetch!(opts, :mapping)

    edit(sources, fn ast -> ast |> steps() |> Enum.map(&step(&1, mapping)) end)
  end

  defp steps(ast) do
    {_, found} =
      Macro.prewalk(ast, [], fn
        {:moments, _, args} = node, found when is_list(args) ->
          {node, found ++ moment_steps(do_body(args))}

        node, found ->
          {node, found}
      end)

    found
  end

  defp moment_steps(section) do
    for {:moment, _, args} <- calls(statements(section), :moment),
        step <- calls(statements(do_body(args)), :step),
        do: step
  end

  defp step({:step, _, args} = step, mapping) do
    keyword_tap(step, args, mapping) || block_tap(step, args, mapping)
  end

  defp keyword_tap(step, args, mapping) do
    Enum.find_value(keywords(args), fn
      {:tap, key, value} -> verb_for(step, value, mapping, &replace(key, value, "verb: #{&1}"))
      _ -> nil
    end)
  end

  defp block_tap(step, args, mapping) do
    Enum.find_value(calls(statements(do_body(args)), :tap), fn {:tap, _, [value]} = tap ->
      verb_for(step, value, mapping, &replace(tap, tap, "verb #{&1}"))
    end)
  end

  defp verb_for(step, value, mapping, patch) do
    key = literal(value)

    cond do
      not is_binary(key) ->
        nil

      verbs = mapping["conflicts"][key] ->
        {:skip,
         %{
           line: line(step),
           reason: "VerbGates place #{inspect(key)} for #{Enum.join(verbs, ", ")}"
         }}

      tuple = tuple(mapping["keys"][key]) ->
        {:patch, patch.(tuple)}

      true ->
        nil
    end
  end

  defp tuple(verb) when is_binary(verb) do
    with [type, name] <- String.split(verb, "."),
         true <- type =~ @name and name =~ @name do
      "{:#{type}, :#{name}}"
    else
      _ -> nil
    end
  end

  defp tuple(_), do: nil
end
