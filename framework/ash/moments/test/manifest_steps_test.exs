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

  defmodule Booking do
    use Ash.Resource,
      domain: Moments.ManifestStepsTest.Bookings,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Mana.Verbs]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
      update(:pay)
      update(:cancel)
    end

    verbs do
      verb(:pay)
      verb(:cancel)
    end
  end

  defmodule Bookings do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
      resource(Moments.ManifestStepsTest.Booking)
    end

    moments do
      route("/bookings")
      field(:page, 0, min: 0, max: 9)

      moment :pay_booking do
        description("A booking paid through its own control.")
        step(:pay, verb: {:booking, :pay}, on: "booking.id", until: [:paid])
        step(:cancel, verb: {Moments.ManifestStepsTest.Booking, :cancel})
        check(:paid, kind: :not_offered, verb: {:booking, :pay}, scope: :step)
        check(:cancellable, kind: :offered, verb: {:booking, :cancel})
      end
    end
  end

  defmodule Elsewhere do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/elsewhere")
      field(:page, 0, min: 0, max: 9)

      moment :pay_elsewhere do
        description("Names the type of a resource another exported domain holds.")
        step(:pay, verb: {:booking, :pay})
        check(:paid, kind: :not_offered, verb: {:booking, :pay})
      end
    end
  end

  defmodule UndeclaredStep do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/refund")
      field(:page, 0, min: 0, max: 9)

      moment :refund do
        description("Taps a verb the booking does not declare.")
        step(:refund, verb: {Moments.ManifestStepsTest.Booking, :refund})
        check(:page, kind: :ui_equals, field: :page, equals: 0)
      end
    end
  end

  defmodule UndeclaredCheck do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/refund-offered")
      field(:page, 0, min: 0, max: 9)

      moment :refund_offered do
        description("Expects a verb the booking does not declare.")
        check(:refundable, kind: :offered, verb: {Moments.ManifestStepsTest.Booking, :refund})
      end
    end
  end

  defmodule MisplacedRecord do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/misplaced")
      field(:page, 0, min: 0, max: 9)

      moment :misplaced do
        description("Names a record for a gesture that is not a verb.")
        step(:open, tap: "booking-row", on: "booking.id")
        check(:page, kind: :ui_equals, field: :page, equals: 0)
      end
    end
  end

  test "a verb step taps its control's key and names the verb; on: is its record's reference" do
    scene = Moments.Manifest.build(Bookings)["moments"]["pay-booking"]

    assert [
             %{"kind" => "tap", "target" => "verb:booking.pay", "verb" => "booking.pay", "inputRef" => "booking.id", "until" => ["paid"]},
             %{"kind" => "tap", "target" => "verb:booking.cancel", "verb" => "booking.cancel"} = cancel
           ] = scene["steps"]

    refute Map.has_key?(cancel, "inputRef")

    assert [
             %{"name" => "paid", "kind" => "not_offered", "verb" => "booking.pay", "scope" => "step"},
             %{"name" => "cancellable", "kind" => "offered", "verb" => "booking.cancel"}
           ] = scene["checks"]
  end

  test "a resource type resolves across the exported domains" do
    manifest = Moments.Manifest.build_many([Bookings, Elsewhere])
    assert [%{"target" => "verb:booking.pay"}] = manifest["moments"]["pay-elsewhere"]["steps"]

    assert_raise ArgumentError, ~r/no resource of type :booking/, fn -> Moments.Manifest.build(Elsewhere) end
  end

  test "the export refuses a verb the resource does not declare" do
    assert_raise ArgumentError, ~r/declares no verb :refund/, fn -> Moments.Manifest.build(UndeclaredStep) end
    assert_raise ArgumentError, ~r/declares no verb :refund/, fn -> Moments.Manifest.build(UndeclaredCheck) end
    assert_raise ArgumentError, ~r/on names the record of a verb step/, fn -> Moments.Manifest.build(MisplacedRecord) end
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
