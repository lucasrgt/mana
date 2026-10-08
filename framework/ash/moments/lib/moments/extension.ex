defmodule Moments.Field do
  @moduledoc false
  defstruct [
    :name,
    :default,
    :values,
    :min,
    :max,
    :max_length,
    :max_entries,
    :restore,
    :__identifier__,
    :__spark_metadata__
  ]
end

defmodule Moments.Check do
  @moduledoc false
  defstruct [:name, :kind, :field, :equals, :match, :scope, :__identifier__, :__spark_metadata__]
end

defmodule Moments.Scene do
  @moduledoc false
  defstruct [
    :name,
    :from,
    :description,
    :backend,
    :platforms,
    :__identifier__,
    :__spark_metadata__,
    defaults: [],
    checks: [],
    steps: []
  ]
end

defmodule Moments.Step do
  @moduledoc false
  defstruct [:name, :tap, :fill, :from, :reveal, :until, :__identifier__, :__spark_metadata__]
end

defmodule Moments.Extension do
  @moduledoc """
  Development moments on an Ash Domain/Resource. Describes UI projections and
  selects a registered app-owned backend recipe by name.
  """
  @field %Spark.Dsl.Entity{
    name: :field,
    target: Moments.Field,
    args: [:name, :default],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      default: [type: :any, required: true],
      values: [type: {:list, :string}],
      min: [type: :non_neg_integer],
      max: [type: :non_neg_integer],
      max_length: [type: :pos_integer],
      max_entries: [type: :pos_integer],
      restore: [type: :boolean, default: true]
    ]
  }
  @check %Spark.Dsl.Entity{
    name: :check,
    target: Moments.Check,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      kind: [type: {:in, [:restored, :ui_equals, :backend_equals]}, required: true],
      field: [type: :atom],
      equals: [type: :any],
      match: [type: :atom],
      scope: [type: {:in, [:step, :final]}, default: :final]
    ]
  }
  @step %Spark.Dsl.Entity{
    name: :step,
    target: Moments.Step,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      tap: [type: :string],
      fill: [type: :string],
      reveal: [type: :string],
      from: [type: :string],
      until: [type: {:list, :atom}, default: []]
    ]
  }
  @scene %Spark.Dsl.Entity{
    name: :moment,
    target: Moments.Scene,
    entities: [checks: [@check], steps: [@step]],
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      from: [type: :atom, doc: "Parent Moment; declares ancestry, not a backend base or execution dependency."],
      description: [type: :string, required: true],
      backend: [type: :atom],
      platforms: [
        type: {:list, {:in, [:web, :native]}},
        doc: "Where the situation exists (e.g. `[:web]` for a web-only button); omitted means every platform."
      ],
      defaults: [type: :keyword_list, default: []]
    ]
  }
  @section %Spark.Dsl.Section{
    name: :moments,
    describe: "Named development situations and their explicit restorable UI state.",
    schema: [
      route: [type: :string, required: true],
      base: [type: :atom],
      live_ui_prefix: [type: :string],
      watch: [type: {:list, :string}, default: []],
      client_roots: [type: {:list, :string}, default: []]
    ],
    entities: [@field, @scene]
  }
  use Spark.Dsl.Extension, sections: [@section]
end
