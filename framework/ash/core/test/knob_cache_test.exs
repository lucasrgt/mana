defmodule KnobCacheTest.KnobValue do
  use Ash.Resource,
    domain: KnobCacheTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Knobs.Store]
end

defmodule KnobCacheTest.Domain do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(KnobCacheTest.KnobValue)
  end
end

defmodule KnobCacheTest.Knobs do
  use Mana.Knobs, store: KnobCacheTest.KnobValue

  knob(:limit, :integer, default: 10)
end

defmodule Mana.KnobCacheTest do
  use ExUnit.Case, async: false

  alias KnobCacheTest.Knobs
  alias Mana.Knobs.Cache

  setup do
    previous = Application.get_env(:mana_core, :knob_ttl_ms)
    Application.put_env(:mana_core, :knob_ttl_ms, 60_000)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mana_core, :knob_ttl_ms, previous),
        else: Application.delete_env(:mana_core, :knob_ttl_ms)

      for row <- Ash.read!(KnobCacheTest.KnobValue), do: Ash.destroy!(row)
    end)
  end

  # Another node changing the knob: the row changes, this node's cache does not hear of it.
  defp store_elsewhere(name, value),
    do:
      KnobCacheTest.KnobValue
      |> Ash.Changeset.for_create(:set, %{name: name, value: %{"value" => value}})
      |> Ash.create!()

  test "without Mana.Knobs.Cache running, reading or changing a knob names the missing child" do
    assert_raise RuntimeError, ~r/Mana.Knobs.Cache is not running/, fn -> Knobs.get(:limit) end
    assert_raise RuntimeError, ~r/supervision tree/, fn -> Knobs.set(:limit, 3, nil) end
  end

  describe "with Mana.Knobs.Cache running" do
    setup do
      start_supervised!(Cache)
      :ok
    end

    test "a change elsewhere shows once the TTL passes; one made here shows at once" do
      assert Knobs.get(:limit) == 10
      store_elsewhere("limit", 20)
      assert Knobs.get(:limit) == 10

      Application.put_env(:mana_core, :knob_ttl_ms, 0)
      assert Knobs.get(:limit) == 20

      Application.put_env(:mana_core, :knob_ttl_ms, 60_000)
      assert {:ok, _} = Knobs.set(:limit, 30, nil)
      assert Knobs.get(:limit) == 30
      assert :ok = Knobs.unset(:limit)
      assert Knobs.get(:limit) == 10
    end

    test "reads that refresh from the store never write :persistent_term" do
      Application.put_env(:mana_core, :knob_ttl_ms, 0)
      assert Knobs.get(:limit) == 10

      before = :persistent_term.get()

      for value <- 1..5 do
        store_elsewhere("limit", value)
        assert Knobs.get(:limit) == value
      end

      assert :persistent_term.get() -- before == []
    end

    test "scoped values are read from the store every time" do
      Application.put_env(:mana_core, :knob_scopes, true)
      on_exit(fn -> Application.delete_env(:mana_core, :knob_scopes) end)

      scope = Knobs.scoped(%{limit: 5})
      Mana.Knobs.put_scope(scope)

      assert Knobs.get(:limit) == 5
      store_elsewhere("limit@#{scope}", 6)
      assert Knobs.get(:limit) == 6
    end

    test "the supervised process owns a read-concurrent table, empty again when it starts over" do
      owner = Process.whereis(Cache)
      assert :ets.info(Cache, :owner) == owner
      assert :ets.info(Cache, :read_concurrency)

      assert Knobs.get(:limit) == 10
      store_elsewhere("limit", 40)

      stop_supervised!(Cache)
      start_supervised!(Cache)

      assert Knobs.get(:limit) == 40
    end
  end
end
