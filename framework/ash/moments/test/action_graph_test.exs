defmodule Moments.ActionGraphTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  # Each module lives in a file of its own, the way xref sees a project.
  @sources %{
    "common.ex" => """
    defmodule Effect.Common do
      def round(value), do: value
    end
    """,
    "pay_helper.ex" => """
    defmodule Effect.PayHelper do
      def total(changeset), do: changeset
    end
    """,
    "pay_change.ex" => """
    defmodule Effect.PayChange do
      use Ash.Resource.Change
      def change(changeset, _opts, _context), do: changeset |> Effect.PayHelper.total() |> Effect.Common.round()
    end
    """,
    "cancel_change.ex" => """
    defmodule Effect.CancelChange do
      use Ash.Resource.Change
      def change(changeset, _opts, _context), do: changeset
    end
    """,
    "list_prep.ex" => """
    defmodule Effect.ListPrep do
      use Ash.Resource.Preparation
      def prepare(query, _opts, _context), do: Effect.Common.round(query)
    end
    """,
    "calc.ex" => """
    defmodule Effect.Calc do
      use Ash.Resource.Calculation
      def calculate(records, _opts, _context), do: Enum.map(records, fn _ -> 1 end)
    end
    """,
    "booking.ex" => """
    defmodule Effect.Booking do
      use Ash.Resource,
        domain: Effect.Bookings,
        data_layer: Ash.DataLayer.Ets,
        extensions: [Mana.Verbs]

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:create])
        read(:list, prepare: Effect.ListPrep)

        update :pay do
          require_atomic?(false)
          change(Effect.PayChange)
        end

        update :cancel do
          require_atomic?(false)
          change(Effect.CancelChange)
        end
      end

      calculations do
        calculate(:total, :integer, Effect.Calc)
      end

      verbs do
        verb(:pay)
        verb(:withdraw, action: :cancel)
      end
    end

    defmodule Effect.Receipt do
      use Ash.Resource, domain: Effect.Bookings, data_layer: Ash.DataLayer.Ets

      attributes do
        uuid_primary_key(:id)
      end

      actions do
        defaults([:read, :create])
      end
    end
    """,
    "bookings.ex" => """
    defmodule Effect.Bookings do
      use Ash.Domain, validate_config_inclusion?: false

      resources do
        resource(Effect.Booking)
        resource(Effect.Receipt)
      end
    end
    """,
    "recipes.ex" => """
    defmodule Effect.Recipes do
      use Moments.RecipeSet, observe: :observe

      recipe :booking_paid, "A paid booking." do
        _ = Effect.Booking
        %{"route" => "/bookings"}
      end

      def observe(_launch, projection), do: {:ok, projection}
    end
    """
  }

  # What `mix xref graph` reports for those files.
  @edges %{
    "booking.ex" => ~w(bookings.ex list_prep.ex pay_change.ex cancel_change.ex calc.ex),
    "pay_change.ex" => ~w(pay_helper.ex common.ex booking.ex),
    "list_prep.ex" => ~w(common.ex),
    "bookings.ex" => ~w(booking.ex),
    "recipes.ex" => ~w(booking.ex)
  }

  @modules [
    Effect.Common,
    Effect.PayHelper,
    Effect.PayChange,
    Effect.CancelChange,
    Effect.ListPrep,
    Effect.Calc,
    Effect.Booking,
    Effect.Receipt,
    Effect.Bookings,
    Effect.Recipes
  ]

  @manifest %{
    "moments" => %{
      "pay" => %{"steps" => [%{"name" => "pay", "verb" => "booking.pay"}]},
      "withdraw" => %{"steps" => [%{"name" => "withdraw", "verb" => "booking.withdraw"}]},
      "look" => %{"steps" => []}
    }
  }

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "moments-action-graph-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    files =
      for {name, source} <- @sources, do: Path.join(root, name) |> tap(&File.write!(&1, source))

    {:ok, _modules, %{compile_warnings: [], runtime_warnings: []}} =
      Kernel.ParallelCompiler.compile(files, return_diagnostics: true)

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp graph(root, extra \\ %{}) do
    files = Map.keys(@sources) ++ Map.keys(extra)

    Map.new(files, fn name ->
      deps = Map.get(@edges, name, []) ++ Map.get(extra, name, [])
      {Path.join(root, name), Enum.map(deps, &Path.join(root, &1))}
    end)
  end

  defp build(root, graph, modules \\ @modules),
    do: Moments.ActionGraph.build(@manifest, graph, &Path.relative_to(&1, root), modules: modules)

  test "a file only an action's changes reach is that action's effect", %{root: root} do
    map = build(root, graph(root))

    assert map["version"] == 1
    assert map["status"] == "available"

    assert map["effects"] == %{
             "pay_change.ex" => ["Effect.Booking.pay"],
             "pay_helper.ex" => ["Effect.Booking.pay"],
             "cancel_change.ex" => ["Effect.Booking.cancel"]
           }
  end

  test "a file a read, a calculation or a resource reaches is never an effect", %{root: root} do
    effects = build(root, graph(root))["effects"]

    # common.ex is shared with the read's preparation; calc.ex and the
    # resource's own file are read by every query.
    for file <- ~w(common.ex list_prep.ex calc.ex booking.ex bookings.ex recipes.ex),
        do: refute(Map.has_key?(effects, file), file)
  end

  test "a file anything outside the actions calls keeps the file graph", %{root: root} do
    effects = build(root, graph(root, %{"web.ex" => ~w(pay_helper.ex)}))["effects"]

    refute Map.has_key?(effects, "pay_helper.ex")
    assert effects["pay_change.ex"] == ["Effect.Booking.pay"]
  end

  test "verbs name the action they run and recipes the resources they reach", %{root: root} do
    map = build(root, graph(root))

    assert map["verbs"] == %{
             "booking.pay" => "Effect.Booking.pay",
             "booking.withdraw" => "Effect.Booking.cancel"
           }

    # Both resources of the file the recipe reaches.
    assert map["recipes"] == %{"booking-paid" => ["Effect.Booking", "Effect.Receipt"]}
  end

  test "a resource outside the compiled project makes the map unavailable", %{root: root} do
    graph = Map.delete(graph(root), Path.join(root, "booking.ex"))

    warning = capture_io(:stderr, fn -> send(self(), {:map, build(root, graph)}) end)

    assert_received {:map, %{"version" => 1, "status" => "unavailable"} = map}
    assert map_size(map) == 2

    assert warning =~
             ~r/Moments action graph is unavailable: Effect\.(Booking|Receipt) is outside the compiled project/
  end
end
