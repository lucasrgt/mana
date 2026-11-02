defmodule ManaLint.Check.AggregateInElixir do
  use Credo.Check,
    base_priority: :normal,
    category: :design,
    param_defaults: [allowed_paths: ManaLint.Code.fixture_paths()],
    explanations: [
      check: """
      Flags the records of an Ash read (or a field mapped out of them)
      summed, counted, averaged or maxed in Elixir: `length/1`,
      `Enum.count`, `Enum.sum`, `Enum.max`/`min` (and their `_by` forms) over
      `Ash.read!` or a variable bound to it.

      Every row travels to the application to produce one number. The number
      is then usually stored (a denormalized average or counter kept up to
      date by hand in an `after_action`), so it drifts: concurrent writes
      race, a direct write misses the update, and something has to repair it.

      Instead, let the database compute it, where it is always current:

          aggregates do
            avg :average_rating, :reviews, :rating, filter: expr(status != :removed)
            count :total_reviews, :reviews
            max :last_message_at, :messages, :inserted_at
          end

      or, for a one-off number, `Ash.count/2`, `Ash.sum/3`, `Ash.max/3`,
      `Ash.avg/3` on the query.
      """,
      params: [
        allowed_paths:
          "Paths (regexes or substrings) where counting read records is fine (tests, fixtures)."
      ]
    ]

  alias ManaLint.{Code, Reads}

  @enum ~w(count sum max min max_by min_by sum_by count_by product)a

  @impl true
  def run(%SourceFile{} = source_file, params) do
    if Code.listed?(Params.get(params, :allowed_paths, __MODULE__), source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      for module <- source_file |> Code.ast() |> Code.modules(),
          clause <- Code.defs(module),
          {node, line} <- aggregates(clause, module) |> Enum.uniq_by(&elem(&1, 1)) do
        Code.issue(__MODULE__, issue_meta, node, message(node, module, line))
      end
    end
  end

  # One finding per read (its first aggregation). A read limited to a page
  # (`limit(page + 1)` to know whether there is more) is not a table.
  defp aggregates(clause, module) do
    vars = Reads.vars(clause.body, module, Reads.fresh())

    for node <- Code.nodes(clause.body),
        records = aggregated(node, module),
        records != nil,
        read = Reads.source(records, vars, module, Reads.fresh()),
        read != nil,
        not limited?(read, module),
        uniq: true,
        do: {node, Code.line(read)}
  end

  defp limited?(read, module) do
    read
    |> Code.nodes()
    |> Enum.any?(fn node ->
      Code.calls?(node, module, "Ash.Query", [:limit, :page]) or
        match?({key, _} when key in [:limit, :page], node)
    end)
  end

  defp aggregated(node, module) do
    case Code.call(node, module) do
      %{module: nil, fun: :length, args: [records]} -> records
      %{module: "Enum", fun: fun, args: [records | _]} when fun in @enum -> records
      _ -> nil
    end
  end

  defp message(node, module, line),
    do:
      "`#{Code.name(Code.call(node, module))}` over the records of the read on line #{line}: " <>
        "every row is loaded to compute one value. Declare an aggregate or use `Ash.count/sum/max/avg`."
end
