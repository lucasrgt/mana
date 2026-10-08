defmodule Mana.Views.View do
  @moduledoc false
  defstruct [:name, :fields, :live, :describe, :entry, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Views do
  @moduledoc """
  What each screen reads from a resource, declared once:

      views do
        view :agenda_card, fields: [:status, :scheduled_for, :service_name, :verbs], live: true
      end

  A field is a public attribute, calculation or aggregate; compilation fails
  otherwise. A read serving a view loads exactly its calculations and
  aggregates with `prepare({Mana.Views.Load, view: :agenda_card})`. The
  contract carries the views as `x-mana-views` on the resource schema, each
  view's fields plus the attributes that can never be nil (a typed client
  needs them to decode a record); the generated Dart client exposes them as
  `<Type>Views.<view>` whose `sparse` is the JSON:API fieldset
  (`fields[type]=...`) that asks the server for nothing more. `live: true`
  marks views whose screens follow `Mana.Entity` announcements.
  """

  @view %Spark.Dsl.Entity{
    name: :view,
    target: Mana.Views.View,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      fields: [type: {:list, :atom}, required: true, doc: "Public attributes, calculations or aggregates the screen reads."],
      live: [type: :boolean, default: false, doc: "The screen follows Mana.Entity announcements."],
      describe: [type: :string, doc: "The screen or component this view feeds."],
      entry: [type: :atom, doc: "A read action that lists records in this view; agents `open` it (`Mana.Agent`)."]
    ]
  }

  @views %Spark.Dsl.Section{name: :views, entities: [@view]}

  use Spark.Dsl.Extension, sections: [@views], transformers: [Mana.Views.Validate]
  use Mana.Primitive, contract: "x-mana-views", catalog: "views", moments: [:observe]

  @doc "Moments `observe`: `record` as its view `name` reads it, field by field."
  def observe(record, name) do
    resource = record.__struct__
    loaded = Ash.load!(record, loads(resource, name), authorize?: false)
    Map.new(view!(resource, name).fields, &{to_string(&1), Map.get(loaded, &1)})
  end

  def declared(resource), do: Spark.Dsl.Extension.get_entities(resource, [:views])

  def view!(resource, name),
    do: Enum.find(declared(resource), &(&1.name == name)) || raise(ArgumentError, "#{inspect(resource)} has no view #{inspect(name)}")

  @doc "The calculations and aggregates a read must load for `view`."
  def loads(resource, name) do
    loadable =
      MapSet.new(Ash.Resource.Info.public_calculations(resource) ++ Ash.Resource.Info.public_aggregates(resource), & &1.name)

    resource |> view!(name) |> Map.fetch!(:fields) |> Enum.filter(&(&1 in loadable))
  end

  @impl Mana.Primitive
  def contract(resource) do
    required =
      for attribute <- Ash.Resource.Info.public_attributes(resource),
          not attribute.allow_nil? and attribute.name != :id,
          do: attribute.name

    for view <- declared(resource) do
      fields = Enum.uniq(view.fields ++ required)

      %{"name" => to_string(view.name), "fields" => Enum.map(fields, &to_string/1), "live" => view.live}
      |> then(&if view.describe, do: Map.put(&1, "describe", view.describe), else: &1)
    end
  end
end

defmodule Mana.Views.Load do
  @moduledoc "Loads the calculations and aggregates the `view` option names, and nothing else."
  use Ash.Resource.Preparation

  @impl true
  def init(opts) do
    if is_atom(opts[:view]) and not is_nil(opts[:view]), do: {:ok, opts}, else: {:error, "Mana.Views.Load needs view: :name"}
  end

  @impl true
  def prepare(query, opts, _context), do: Ash.Query.load(query, Mana.Views.loads(query.resource, opts[:view]))
end

defmodule Mana.Views.Validate do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: true

  def transform(dsl) do
    module = Transformer.get_persisted(dsl, :module)

    public =
      [[:attributes], [:calculations], [:aggregates]]
      |> Enum.flat_map(&Transformer.get_entities(dsl, &1))
      |> Enum.filter(&Map.get(&1, :public?, false))
      |> MapSet.new(& &1.name)
      |> MapSet.put(:id)

    Enum.reduce_while(Transformer.get_entities(dsl, [:views]), {:ok, dsl}, fn view, ok ->
      case Enum.reject(view.fields, &(&1 in public)) do
        [] ->
          {:cont, ok}

        missing ->
          {:halt,
           {:error,
            Spark.Error.DslError.exception(
              module: module,
              path: [:views, view.name],
              message: "view #{inspect(view.name)} reads fields that are not public: #{inspect(missing)}"
            )}}
      end
    end)
  end
end
