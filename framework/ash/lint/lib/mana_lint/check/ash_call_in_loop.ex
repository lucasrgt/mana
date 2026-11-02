defmodule ManaLint.Check.AshCallInLoop do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    param_defaults: [allowed_paths: ManaLint.Code.fixture_paths()],
    explanations: [
      check: """
      Flags an Ash read or write (`Ash.get`, `read`, `read_one`, `exists?`,
      `count`, `load`, `calculate`, `create`, `update`, `destroy`) run once per
      element of `Enum.*`, `Stream.*` or `for` over records that came from an
      Ash read in the same function — directly, or in a function of the module
      called from the loop.

      That is N+1: one query for the list, then one or more per record, all
      in sequence. The latency grows with the data, the pool is held for the
      whole loop, and a write per record is a transaction per record.

      Instead:

      - load what each record needs with the read (`Ash.Query.load/2` of a
        relationship, an aggregate or a calculation);
      - read the related records once (`filter(id in ^ids)`) and match them in
        memory;
      - write them in one go: `Ash.bulk_update(query, :action, input,
        strategy: :atomic)`, `Ash.bulk_create/4`, `Ash.bulk_destroy/4`;
      - for a periodic sweep, let the resource declare it (a `Mana.Entity`
        deadline, `Mana.Retention`, an AshOban trigger).
      """,
      params: [
        allowed_paths:
          "Paths (regexes or substrings) where per-record calls are fine (tests, fixtures)."
      ]
    ]

  alias ManaLint.{Code, Reads}

  @per_record ~w(get get! read read! read_one read_one! exists exists? count count! load load!
                 calculate calculate! aggregate aggregate! create create! update update! destroy destroy!)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Code.listed?(Params.get(params, :allowed_paths, __MODULE__), source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      for module <- source_file |> Code.ast() |> Code.modules(),
          clause <- Code.defs(module),
          issue <- clause_issues(clause, module) do
        issue
      end
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.map(fn {node, message} -> Code.issue(__MODULE__, issue_meta, node, message) end)
    end
  end

  defp clause_issues(clause, module) do
    vars = Reads.vars(clause.body, module)

    for node <- Code.nodes(clause.body),
        {each, read} <- Reads.per_element(node, vars, module),
        inner <- Code.nodes(each),
        issue <- inner_issue(inner, module, Code.line(read)),
        do: issue
  end

  defp inner_issue(node, module, line) do
    cond do
      Code.calls?(node, module, "Ash", @per_record) ->
        [{node, message("`#{Code.name(Code.call(node, module))}`", line)}]

      helper = per_record_helper(node, module) ->
        {at, name, call} = helper
        [{at, message("`#{name}` (which calls `#{Code.name(call)}`)", line)}]

      true ->
        []
    end
  end

  # A function of the module, called per record, that queries.
  defp per_record_helper(node, module) do
    with {at, name} <- local(node, module),
         inner when inner != nil <-
           module
           |> Code.clauses(name)
           |> Enum.flat_map(&Code.nodes(&1.body))
           |> Enum.find(&Code.calls?(&1, module, "Ash", @per_record)) do
      {at, name, Code.call(inner, module)}
    else
      _ -> nil
    end
  end

  defp local(node, module) do
    case {Code.local_capture(node), Code.call(node, module)} do
      {{name, meta}, _} -> {{name, meta, nil}, name}
      {nil, %{module: nil, fun: name}} -> {node, name}
      _ -> nil
    end
  end

  defp message(what, line),
    do:
      "#{what} runs once per record of the read on line #{line} (N+1). " <>
        "Load it with the read (relationship, aggregate, calculation) or batch it (one read, a bulk action)."
end
