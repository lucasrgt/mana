defmodule Moments.ManifestStepsTest do
  use ExUnit.Case, async: true

  defmodule Gestures do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/start")
      field(:page, 0, min: 0, max: 9)

      moment :every_gesture do
        description("Every kind of step a journey can take.")
        step(:pick, tap: "list.option-52", until: [:moved])
        step(:name, fill: "form.name", from: "person.name")
        step(:send, submit: "form.name")
        step(:show, reveal: "form.footer")
        step(:next, swipe: "gallery.pages", direction: :left, until: [:moved])
        step(:menu, long_press: "list.row")
        step(:close, back: true)
        check(:moved, kind: :ui_equals, field: :page, equals: 1, scope: :step)
        check(:done, kind: :ui_equals, field: :page, equals: 1)
      end
    end
  end

  test "each step exports its kind, target and, for a swipe, its direction" do
    steps =
      Moments.Manifest.build(Gestures)
      |> Map.fetch!("moments")
      |> Map.fetch!("every-gesture")
      |> Map.fetch!("steps")

    assert [
             %{"kind" => "tap", "target" => "list.option-52"},
             %{"kind" => "fill", "target" => "form.name", "inputRef" => "person.name"},
             %{"kind" => "submit", "target" => "form.name"},
             %{"kind" => "reveal", "target" => "form.footer"},
             %{"kind" => "swipe", "target" => "gallery.pages", "direction" => "left"},
             %{"kind" => "long_press", "target" => "list.row"},
             %{"kind" => "back", "target" => "system.back"}
           ] = steps

    refute Enum.any?(steps, &(&1["kind"] != "swipe" and Map.has_key?(&1, "direction")))
  end
end
