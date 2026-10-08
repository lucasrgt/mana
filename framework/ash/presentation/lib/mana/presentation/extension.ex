defmodule Mana.Presentation.Input do
  @moduledoc false
  defstruct [:name, :label, :key, :invalid, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Presentation.Form do
  @moduledoc false
  defstruct [
    :name,
    :action,
    :transport,
    :create_identity,
    :submit,
    :submit_key,
    :failure,
    :__identifier__,
    :__spark_metadata__,
    inputs: []
  ]
end

defmodule Mana.Presentation.Extension do
  @moduledoc "Compile-time presentation declarations; resource actions remain authoritative."
  @input %Spark.Dsl.Entity{
    name: :input,
    target: Mana.Presentation.Input,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      label: [type: :string, required: true],
      key: [type: :string, required: true],
      invalid: [type: :string, required: true]
    ]
  }
  @form %Spark.Dsl.Entity{
    name: :form,
    target: Mana.Presentation.Form,
    args: [:name],
    identifier: :name,
    entities: [inputs: [@input]],
    schema: [
      name: [type: :atom, required: true],
      action: [type: :atom, required: true],
      transport: [type: {:in, [:callback, :json_api]}, default: :callback],
      create_identity: [type: :atom, doc: "Accepted UUID primary key supplied once by the caller for a creation attempt; not an upsert or retry policy."],
      submit: [type: :string, required: true],
      submit_key: [type: :string, required: true],
      failure: [type: :string, required: true]
    ]
  }
  @forms %Spark.Dsl.Section{name: :forms, entities: [@form]}
  use Spark.Dsl.Extension, sections: [@forms]
end
