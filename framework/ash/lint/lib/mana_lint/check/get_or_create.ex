defmodule ManaLint.Check.GetOrCreate do
  use Credo.Check,
    base_priority: :normal,
    category: :warning,
    explanations: [
      check: """
      Flags get-or-create written as two steps on one resource: a `read_one`
      (or `get`) and, when it finds nothing, a `create` —
      `read_one!(q) || create(...)`, `case read_one(q) do {:ok, nil} ->
      create(...)`, `with nil <- read_one!(q)`, or a variable from the read
      tested with `if`/`||` before a create.

      Two requests at once both read nothing and both create: a duplicate,
      or a unique-index error that one of them shows the user. Swallowing
      that error and reading again (a common fix) hides every other reason the
      create failed.

      Instead, declare an identity and let the database decide in one
      statement:

          identities do
            identity :one_per_pair, [:participant_a_id, :participant_b_id]
          end

          create :open do
            upsert? true
            upsert_identity :one_per_pair
            upsert_fields []
          end
      """
    ]

  alias ManaLint.Code

  @finds ~w(read_one read_one! get get!)a
  @creates ~w(create create!)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for module <- source_file |> Code.ast() |> Code.modules(),
        clause <- Code.defs(module),
        found = finds(clause.body, module),
        node <- Code.nodes(clause.body),
        {find, create} <- get_or_create(node, module, found),
        same_resource?(find, create, module),
        uniq: true,
        do: Code.issue(__MODULE__, issue_meta, create, message(Code.call(create, module)))
  end

  # Variables bound to a single-record read: name => the read.
  defp finds(body, module) do
    for {:=, _, [{name, _, context}, rhs]} <- Code.nodes(body),
        is_atom(name) and is_atom(context),
        find?(rhs, module),
        into: %{},
        do: {name, rhs}
  end

  defp find?(node, module), do: Code.calls?(node, module, "Ash", @finds)

  defp found(node, module, found) do
    cond do
      find?(node, module) -> node
      match?({name, _, c} when is_atom(name) and is_atom(c), node) -> found[elem(node, 0)]
      true -> nil
    end
  end

  defp get_or_create({:||, _, [left, right]}, module, found),
    do: pair(found(left, module, found), right, module)

  defp get_or_create({:case, _, [subject, [do: clauses]]}, module, found) do
    case found(subject, module, found) do
      nil ->
        []

      find ->
        for {:->, _, [[pattern], body]} <- clauses,
            nothing?(pattern),
            pair <- pair(find, body, module),
            do: pair
    end
  end

  defp get_or_create({:with, _, args}, module, found) do
    for {:<-, _, [pattern, rhs]} <- args,
        nothing?(pattern),
        find = found(rhs, module, found),
        find != nil,
        options <- Enum.filter(args, &is_list/1),
        pair <- pair(find, Keyword.get(options, :do), module),
        do: pair
  end

  defp get_or_create({branch, _, [condition, options]}, module, found)
       when branch in [:if, :unless] and is_list(options) do
    case {branch, tested(condition, module, found)} do
      {_, nil} -> []
      {:if, {find, :present}} -> pair(find, Keyword.get(options, :else), module)
      {:if, {find, :absent}} -> pair(find, Keyword.get(options, :do), module)
      {:unless, {find, :present}} -> pair(find, Keyword.get(options, :do), module)
      {:unless, {find, :absent}} -> pair(find, Keyword.get(options, :else), module)
    end
  end

  defp get_or_create(_, _, _), do: []

  defp tested({:is_nil, _, [subject]}, module, found),
    do: tested_as(subject, :absent, module, found)

  defp tested({:!, _, [subject]}, module, found), do: tested_as(subject, :absent, module, found)
  defp tested({:not, _, [subject]}, module, found), do: tested_as(subject, :absent, module, found)

  defp tested({:==, _, [subject, nil]}, module, found),
    do: tested_as(subject, :absent, module, found)

  defp tested({:=, _, [_, subject]}, module, found),
    do: tested_as(subject, :present, module, found)

  defp tested(subject, module, found), do: tested_as(subject, :present, module, found)

  defp tested_as(subject, how, module, found) do
    case found(subject, module, found) do
      nil -> nil
      find -> {find, how}
    end
  end

  defp nothing?(nil), do: true
  defp nothing?({:ok, nil}), do: true
  defp nothing?(_), do: false

  defp pair(nil, _, _), do: []
  defp pair(_, nil, _), do: []

  defp pair(find, code, module) do
    for node <- Code.nodes(code),
        Code.calls?(node, module, "Ash", @creates),
        not upsert?(node),
        do: {find, node}
  end

  defp upsert?({_, _, args}) do
    args
    |> Code.nodes()
    |> Enum.any?(&match?({:upsert?, true}, &1))
  end

  defp same_resource?(find, create, module) do
    case {root(find, module), root(create, module)} do
      {a, b} when is_binary(a) and is_binary(b) -> a == b
      _ -> true
    end
  end

  # The resource a call starts from: the alias at the head of its first argument.
  defp root({:__aliases__, _, _} = alias, module), do: Code.resolve(alias, module)

  defp root(node, module) do
    case Code.call(node, module) do
      %{args: [first | _]} -> root(first, module)
      _ -> nil
    end
  end

  defp message(call),
    do:
      "`#{Code.name(call)}` after a read that found nothing: get-or-create in two steps races. " <>
        "Declare an identity and create with `upsert?: true`, `upsert_identity:`."
end
