defmodule Mana.Primitive do
  @moduledoc """
  A fullstack primitive: a Spark extension on Ash resources whose
  declaration also reaches the wire and the client.

      defmodule Mana.Verbs do
        use Spark.Dsl.Extension, sections: [@verbs], transformers: [...]
        use Mana.Primitive, contract: "x-mana-verbs", catalog: "verbs"

        @impl Mana.Primitive
        def contract(resource), do: ...
      end

  Its parts: the DSL and server behaviour (the extension itself); the
  contract (`contract/1`, placed by `Mana.Domain.OpenApi.finish` as
  `<contract>` on the resource schema, and listed in `info.x-mana-primitives`);
  the client half (`mana client generate` emits Dart for every
  `x-mana-*` key and refuses a key it has no generator for); discovery (the
  `catalog` id in `framework/catalog.toml`, which `mana doctor` checks); and
  Moments hooks (`moments:` names which of `capture`, `restore`, `fake`,
  `observe` it implements, so a Moment can stand on it reproducibly):
  `observe` reads what the primitive says about a record now, for a
  Moment's assertions; `capture` takes a portable snapshot of a record's
  primitive state and `restore` rebuilds it elsewhere; `fake` stands in for
  what the outside world or the clock would do. Each hook is a public
  function of that name on the primitive (`hooks_implemented?/1` checks it).
  """

  @hooks [:capture, :restore, :fake, :observe]

  @callback contract(Ash.Resource.t()) :: term()

  defmacro __using__(opts) do
    contract = Keyword.fetch!(opts, :contract)
    catalog = Keyword.fetch!(opts, :catalog)
    moments = Keyword.get(opts, :moments, [])

    unless String.starts_with?(contract, "x-mana-"), do: raise(ArgumentError, "a primitive's contract key starts with x-mana-")
    unless moments -- @hooks == [], do: raise(ArgumentError, "Moments hooks are #{inspect(@hooks)}")

    quote do
      @behaviour Mana.Primitive
      def __mana_primitive__, do: %{contract: unquote(contract), catalog: unquote(catalog), moments: unquote(moments)}
    end
  end

  def hooks, do: @hooks

  @doc "Whether every hook `primitive` declares is a function it exports."
  def hooks_implemented?(primitive) do
    exported = primitive.__info__(:functions) |> Keyword.keys() |> MapSet.new()
    Enum.all?(primitive.__mana_primitive__().moments, &MapSet.member?(exported, &1))
  end

  @doc "The primitives a resource uses."
  def of(resource), do: Enum.filter(Spark.extensions(resource), &primitive?/1)

  def primitive?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :__mana_primitive__, 0)

  @doc "Each resource's primitive contracts on its schema, and the primitives used under `info.x-mana-primitives`."
  def put_contracts(spec, domains) do
    spec = Mana.Verbs.put_operations(spec, domains)

    placed =
      for domain <- domains,
          resource <- Ash.Domain.Info.resources(domain),
          AshJsonApi.Resource in Spark.extensions(resource),
          type = to_string(AshJsonApi.Resource.Info.type(resource)),
          is_map(get_in(spec, ["components", "schemas", type])),
          primitive <- of(resource),
          value = primitive.contract(resource),
          value not in [nil, [], %{}],
          do: {type, primitive, value}

    spec =
      Enum.reduce(placed, spec, fn {type, primitive, value}, spec ->
        put_in(spec, ["components", "schemas", type, primitive.__mana_primitive__().contract], value)
      end)

    case placed |> Enum.map(&elem(&1, 1)) |> Enum.uniq() do
      [] ->
        spec

      used ->
        manifest =
          for primitive <- Enum.sort_by(used, & &1.__mana_primitive__().contract) do
            meta = primitive.__mana_primitive__()
            %{"contract" => meta.contract, "catalog" => meta.catalog, "moments" => Enum.map(meta.moments, &to_string/1)}
          end

        Map.update(spec, "info", %{"x-mana-primitives" => manifest}, &Map.put(&1, "x-mana-primitives", manifest))
    end
  end
end
