defmodule Moments.ManifestAppsTest do
  use ExUnit.Case, async: true

  alias Moments.ManifestAppsTest.{
    Counter,
    Desk,
    Duplicate,
    NoApp,
    Owner,
    RivalOwner,
    Shop,
    Single,
    Unowned,
    Unrouted
  }

  defmodule Booking do
    use Ash.Resource,
      domain: Moments.ManifestAppsTest.Shop,
      data_layer: Ash.DataLayer.Ets,
      extensions: [Mana.Verbs]

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read])
      update(:pay)
    end

    verbs do
      verb(:pay)
    end
  end

  # The whole shop app on one domain.
  defmodule Single do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/shop")
      base(:shop_workspace)
      watch(["lib/main.dart"])
      client_roots(["lib/app.dart"])
      field(:page, 0, min: 0, max: 9)
      field(:phase, "idle", values: ["idle", "busy"], restore: false)

      moment :browse do
        description("The shop's front page.")
        backend(:shop_front)
        defaults(page: 1)
      end

      moment :pay_booking do
        from(:browse)
        description("A booking paid through its own control.")
        backend(:accepted_booking)
        platforms([:web])

        step(:pay,
          verb: {Moments.ManifestAppsTest.Booking, :pay},
          on: "booking.id",
          until: [:paid]
        )

        check(:paid,
          kind: :not_offered,
          verb: {Moments.ManifestAppsTest.Booking, :pay},
          scope: :step
        )

        check(:page, kind: :ui_equals, field: :page, equals: 1)
      end
    end
  end

  # The same declarations, split: the app's settings stay on its domain and
  # the booking feature declares its own Moment.
  defmodule Owner do
    use Ash.Domain,
      extensions: [Moments.Extension],
      validate_config_inclusion?: false,
      otp_app: :moments_apps_test

    resources do
    end

    moments do
      app(:shop)
      route("/shop")
      base(:shop_workspace)
      watch(["lib/main.dart"])
      client_roots(["lib/app.dart"])
      field(:page, 0, min: 0, max: 9)
      field(:phase, "idle", values: ["idle", "busy"], restore: false)

      moment :browse do
        description("The shop's front page.")
        backend(:shop_front)
        defaults(page: 1)
      end
    end
  end

  defmodule Shop do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
      resource(Moments.ManifestAppsTest.Booking)
    end

    moments do
      moment :pay_booking do
        app(:shop)
        from(:browse)
        description("A booking paid through its own control.")
        backend(:accepted_booking)
        platforms([:web])

        step(:pay,
          verb: {Moments.ManifestAppsTest.Booking, :pay},
          on: "booking.id",
          until: [:paid]
        )

        check(:paid,
          kind: :not_offered,
          verb: {Moments.ManifestAppsTest.Booking, :pay},
          scope: :step
        )

        check(:page, kind: :ui_equals, field: :page, equals: 1)
      end

      moment :desk_booking do
        app(:desk)
        description("The booking as the desk sees it.")
        step(:pay, verb: {:booking, :pay})
      end
    end
  end

  # An app whose settings a feature's own domain owns.
  defmodule Desk do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:desk)
      route("/desk")
      field(:tab, "open", values: ["open", "closed"])

      moment :desk_queue do
        description("The desk's queue.")
      end
    end
  end

  # A single-domain app that also adds a Moment to the desk.
  defmodule Counter do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      route("/counter")
      field(:page, 0, min: 0, max: 9)

      moment :counter_open do
        description("The counter, open.")
      end

      moment :desk_counter do
        app(:desk)
        description("The desk, reached from the counter.")
      end
    end
  end

  defmodule RivalOwner do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:shop)
      route("/other-shop")

      moment :rival do
        description("A second domain claiming the shop's settings.")
      end
    end
  end

  defmodule Duplicate do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      moment :browse do
        app(:shop)
        description("A second shop Moment named browse.")
        backend(:shop_front)
      end
    end
  end

  defmodule Unrouted do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:shop)
      field(:extra, 0, min: 0, max: 1)

      moment :unrouted do
        description("A field for the shop declared away from its owner.")
      end
    end
  end

  defmodule NoApp do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      moment :lost do
        description("Names neither a route nor an app.")
      end
    end
  end

  defmodule Unowned do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:kiosk)

      moment :orphan do
        description("A Moment of an app no domain owns.")
      end
    end
  end

  defp portable(manifest) do
    manifest
    |> Map.delete("domain")
    |> Map.update!(
      "moments",
      &Map.new(&1, fn {name, scene} -> {name, Map.delete(scene, "source")} end)
    )
  end

  test "splitting an app across domains exports the same manifest" do
    single = Moments.Manifest.build(Single)
    split = Moments.Manifest.build(Owner, domains: [Owner, Shop, Desk])

    assert portable(split) == portable(single)
    assert Jason.encode!(portable(split)) == Jason.encode!(portable(single))
    assert Map.keys(split["moments"]) == ["browse", "pay-booking"]
    assert split["version"] == 3
    assert split["domain"] == inspect(Owner)
  end

  test "an app's Moments come from the domains its OTP app lists" do
    Application.put_env(:moments_apps_test, :ash_domains, [Shop])
    on_exit(fn -> Application.delete_env(:moments_apps_test, :ash_domains) end)

    assert Map.keys(Moments.Manifest.build(Owner)["moments"]) == ["browse", "pay-booking"]
  end

  test "a feature's domain declares Moments for several apps, owned by any domain" do
    domains = [Owner, Shop, Desk, Counter]
    desk = Moments.Manifest.build(Desk, domains: domains)

    assert Map.keys(desk["moments"]) == ["desk-booking", "desk-counter", "desk-queue"]
    assert desk["properties"]["route"] == %{"enum" => ["/desk"]}
    assert Map.keys(desk["properties"]) == ["route", "tab"]
    assert [%{"target" => "verb:booking.pay"}] = desk["moments"]["desk-booking"]["steps"]

    many = Moments.Manifest.build_many([Owner, Desk], domains: domains)
    assert Map.keys(many["screens"]) == ["/desk", "/shop"]

    assert Map.keys(many["moments"]) ==
             ["browse", "desk-booking", "desk-counter", "desk-queue", "pay-booking"]
  end

  test "a single-domain app leaves out the Moments it declares for other apps" do
    assert Map.keys(Moments.Manifest.build(Counter)["moments"]) == ["counter-open"]
  end

  test "an app has exactly one owner of its settings" do
    assert_raise ArgumentError, ~r/app :shop has several owners \(.*Owner, .*RivalOwner\)/, fn ->
      Moments.Manifest.build(Owner, domains: [Owner, Shop, RivalOwner])
    end

    assert_raise ArgumentError, ~r/app :kiosk has no owner/, fn ->
      Moments.Manifest.build(Unowned)
    end
  end

  test "a Moment's name is unique in its app across domains" do
    assert_raise ArgumentError,
                 ~r/duplicate normalized moment name browse in app :shop: .*Owner, .*Duplicate/,
                 fn -> Moments.Manifest.build(Owner, domains: [Owner, Shop, Duplicate]) end
  end

  test "a domain without a route holds no app settings and no Moment without an app" do
    assert_raise ArgumentError, ~r/Unrouted declares app settings without a route/, fn ->
      Moments.Manifest.build(Owner, domains: [Owner, Unrouted])
    end

    assert_raise ArgumentError, ~r/NoApp: moment :lost names no app/, fn ->
      Moments.Manifest.build(Owner, domains: [Owner, NoApp])
    end

    assert_raise ArgumentError, ~r/Shop declares no route and names no app/, fn ->
      Moments.Manifest.build(Shop)
    end
  end

  # Test scripts compile without debug info, and Spark records a declaration's
  # site only with it: these domains are compiled with it.
  @sited """
  defmodule Moments.ManifestAppsTest.SitedItem do
    use Ash.Resource,
      domain: Moments.ManifestAppsTest.SitedFeature,
      data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key(:id)
    end
  end

  defmodule Moments.ManifestAppsTest.SitedFeature do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
      resource(Moments.ManifestAppsTest.SitedItem)
    end

    moments do
      app(:sited)

      moment :item do
        description("A Moment on the feature's domain.")
      end
    end
  end

  defmodule Moments.ManifestAppsTest.SitedApp do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
    end

    moments do
      app(:sited)
      route("/sited")

      moment :home do
        description("The app's own Moment.")
      end
    end
  end
  """

  test "a Moment's source and roots are the domain that declares it and its resources" do
    debug_info = Code.get_compiler_option(:debug_info)
    Code.put_compiler_option(:debug_info, true)

    try do
      Code.compile_string(@sited, __ENV__.file)
    after
      Code.put_compiler_option(:debug_info, debug_info)
    end

    [app, feature] = [Moments.ManifestAppsTest.SitedApp, Moments.ManifestAppsTest.SitedFeature]
    manifest = Moments.Manifest.build(app, domains: [app, feature])
    file = Path.relative_to(__ENV__.file, File.cwd!())

    assert manifest["moments"]["home"]["source"]["module"] == inspect(app)
    assert manifest["moments"]["item"]["source"]["module"] == inspect(feature)

    assert Moments.BackendGraph.roots(manifest, %{file => []}, & &1) == %{
             "home" => [],
             "item" => [file]
           }
  end
end
