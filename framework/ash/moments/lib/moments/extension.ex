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
  defstruct [
    :name,
    :kind,
    :field,
    :equals,
    :match,
    :scope,
    :verb,
    :__identifier__,
    :__spark_metadata__
  ]
end

defmodule Moments.Scene do
  @moduledoc false
  defstruct [
    :name,
    :from,
    :description,
    :backend,
    :platforms,
    :app,
    :exploration,
    :__identifier__,
    :__spark_metadata__,
    defaults: [],
    checks: [],
    steps: []
  ]
end

defmodule Moments.Step do
  @moduledoc false
  defstruct [
    :name,
    :tap,
    :fill,
    :from,
    :reveal,
    :back,
    :swipe,
    :direction,
    :long_press,
    :submit,
    :verb,
    :on,
    :until,
    :__identifier__,
    :__spark_metadata__
  ]
end

defmodule Moments.Extension do
  @moduledoc """
  Development moments on an Ash Domain/Resource. Describes UI projections and
  selects a registered app-owned backend recipe by name.

  A feature's domain can declare Moments for apps whose settings one other
  domain owns (`app`); `Moments.Manifest` collects each app's Moments from
  every domain it is given or the OTP app lists in `:ash_domains`.

  `explorations "priv/moments/explorations"` makes every saved `Mana.Explore`
  trace in that directory (`mix mana.explore --save <name>`) a Moment of the
  section's app, named after its file: running it replays the trace in a
  database of its own and checks the property it broke.
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
      kind: [
        type: {:in, [:restored, :ui_equals, :backend_equals, :offered, :not_offered]},
        required: true
      ],
      field: [type: :atom],
      equals: [type: :any],
      match: [type: :atom],
      verb: [
        type: {:tuple, [:atom, :atom]},
        doc:
          "`{Resource or :type, :verb}` for `:offered` / `:not_offered`: whether a mounted control (`VerbGate`) offers it."
      ],
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
      tap: [type: :string, doc: "Taps the widget with this key."],
      fill: [type: :string, doc: "Types `from`'s value into the text field with this key."],
      reveal: [
        type: :string,
        doc: "Scrolls the widget with this key into view, building it if a lazy list has not yet."
      ],
      back: [
        type: :boolean,
        doc: "Presses the platform's back: closes the dialog or sheet on top, or leaves the page."
      ],
      swipe: [
        type: :string,
        doc:
          "Drags the widget with this key towards `direction` (a page view, a carousel, a dismissible)."
      ],
      direction: [type: {:in, [:left, :right, :up, :down]}, doc: "Where `swipe` drags."],
      long_press: [
        type: :string,
        doc: "Holds the widget with this key past the long-press timeout."
      ],
      submit: [
        type: :string,
        doc:
          "Presses the keyboard's action key (done, search, send) on the text field with this key."
      ],
      verb: [
        type: {:tuple, [:atom, :atom]},
        doc:
          "Taps the control that performs `{Resource or :type, :verb}` (`VerbGate`); the export refuses a verb the resource does not declare."
      ],
      on: [
        type: :string,
        doc:
          "With `verb`, the input reference whose value is the record id: taps that record's control."
      ],
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
      from: [
        type: :atom,
        doc: "Parent Moment: the runner prepares this Moment on the parent's checkpoint."
      ],
      description: [type: :string, required: true],
      backend: [type: :atom],
      platforms: [
        type: {:list, {:in, [:web, :native]}},
        doc:
          "Where the situation exists (e.g. `[:web]` for a web-only button); omitted means every platform."
      ],
      defaults: [type: :keyword_list, default: []],
      app: [
        type: :atom,
        doc:
          "The app whose manifest lists this Moment, when it is not the section's `app`: a feature's domain declares Moments for several apps."
      ]
    ]
  }
  @section %Spark.Dsl.Section{
    name: :moments,
    describe: "Named development situations and their explicit restorable UI state.",
    schema: [
      app: [
        type: :atom,
        doc:
          "Names the app of this section's Moments. With `route`, the domain owns that app's settings (route, base, watch, client_roots, fields); without, it only adds Moments to it."
      ],
      route: [type: :string, doc: "Required on the domain that owns the app's settings."],
      base: [type: :atom],
      watch: [type: {:list, :string}, default: []],
      client_roots: [type: {:list, :string}, default: []],
      explorations: [
        type: :string,
        doc:
          "A directory, from the Mix project root, of saved `Mana.Explore` traces: each `<name>.json` is the Moment `<name>` of this section's app, read when the manifest is exported."
      ]
    ],
    entities: [@field, @scene]
  }
  use Spark.Dsl.Extension, sections: [@section]
end
