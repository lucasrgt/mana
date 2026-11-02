defmodule ManaLint.Check.RecordDateJob do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [
      options: [:scheduled_at, :schedule_in],
      date_fields:
        ~r/(_at|_on|_date|_time|_until)$|^(date|time|deadline|due|expires?|starts?|ends?|check_in|check_out)$/,
      primitives: [~r/^Mana\./]
    ],
    explanations: [
      check: """
      Flags a job built for a record's date: a job (`Worker.new(args,
      scheduled_at: booking.expires_at)`, `Oban.Job.new`) whose
      `scheduled_at:` or `schedule_in:` comes from a record's field — read
      in the option itself or bound to a variable earlier in the function.

      A job inserted for a date the record holds goes stale the moment the
      record changes: moved to another date, it runs at the old one; paid in
      the meantime, it still expires it unless its worker remembers to check
      again; every action that moves the date must find and cancel it.

      Instead, declare the deadline on the resource:

          entity do
            deadline :expire, action: :expire, at: :expires_at, when: expr(status == :pending)
          end

      `Mana.Entity` schedules it in the transaction that makes it due, again
      when the date moves, and asks `when` on the stored row under the
      record's lock before it runs. An event for another system at that date
      is `Mana.Webhook.deliver(name, type, data, at: record.date)`.

      A delay that is not a record's (`schedule_in: 60` for a debounce or a
      backoff) and the jobs of Mana's own workers are left alone.
      """,
      params: [
        options: "The job options that set when it runs.",
        date_fields: "Field names that hold a date (a regex).",
        primitives: "Worker modules (regexes or substrings) of Mana's own primitives."
      ]
    ]

  alias ManaLint.Code

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    scope = %{
      options: Params.get(params, :options, __MODULE__),
      fields: Params.get(params, :date_fields, __MODULE__),
      primitives: Params.get(params, :primitives, __MODULE__)
    }

    for module <- source_file |> Code.ast() |> Code.modules(),
        {nodes, bindings} <- bodies(module),
        node <- nodes,
        %{} = call <- [Code.call(node, module)],
        dated_job?(call, bindings, scope),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, node, message(call))
  end

  # Each function with what its `=` bind, and the module's own code (a
  # change given inline) with nothing bound.
  defp bodies(module) do
    functions =
      for clause <- Code.defs(module) do
        nodes = Code.nodes(clause.body)

        bindings =
          for {:=, _, [pattern, value]} <- nodes,
              name <- Code.pattern_vars(pattern),
              reduce: %{},
              do: (acc -> Map.update(acc, name, [value], &[value | &1]))

        {nodes, bindings}
      end

    functions ++ [{Code.module_nodes(module), %{}}]
  end

  defp dated_job?(%{module: module, fun: :new, args: [_ | _] = args}, bindings, scope)
       when is_binary(module) do
    options = List.last(args)

    not Code.listed?(scope.primitives, module) and Keyword.keyword?(options) and
      Enum.any?(
        scope.options,
        &(Keyword.has_key?(options, &1) and
            record_date?(Keyword.fetch!(options, &1), bindings, scope))
      )
  end

  defp dated_job?(_call, _bindings, _scope), do: false

  defp record_date?(expr, bindings, scope) do
    Code.find(expr, &field?(&1, scope.fields)) != [] or
      expr
      |> Code.find(&match?({name, _, context} when is_atom(name) and is_atom(context), &1))
      |> Enum.any?(fn {name, _, _} ->
        Enum.any?(
          Map.get(bindings, name, []),
          &record_date?(&1, Map.delete(bindings, name), scope)
        )
      end)
  end

  # `booking.expires_at`, `Map.get(booking, :expires_at)`, `booking[:expires_at]`
  # and `Ash.Changeset.get_attribute(changeset, :expires_at)`.
  defp field?({{:., _, [{var, _, context}, field]}, meta, []}, fields)
       when is_atom(var) and is_atom(context) and is_atom(field),
       do: meta[:no_parens] == true and Regex.match?(fields, to_string(field))

  defp field?({{:., _, [target, fun]}, _, [_subject, field | _]}, fields)
       when is_atom(field) do
    reader?(target, fun) and Regex.match?(fields, to_string(field))
  end

  defp field?(_node, _fields), do: false

  defp reader?({:__aliases__, _, [:Map]}, fun), do: fun in [:get, :fetch, :fetch!]
  defp reader?(Access, :get), do: true

  defp reader?({:__aliases__, _, [:Ash, :Changeset]}, fun),
    do: fun in [:get_attribute, :get_data]

  defp reader?(_target, _fun), do: false

  defp message(call),
    do:
      "`#{Code.name(call)}` schedules a job for a record's date: it goes stale when the record moves on. " <>
        "Declare a Mana.Entity deadline (`deadline :name, action: ..., at: :field, when: ...`)."
end
