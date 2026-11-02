defmodule Mana.Knobs.Cache do
  @moduledoc """
  Owns the table `Mana.Knobs` keeps shared knob values in between reads of
  the store. Start it in the application's supervision tree:

      children = [Mana.Knobs.Cache, ...]

  Reading or changing a knob raises while it is not running.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The value cached under `key` when it was read less than `ttl_ms` ago;
  otherwise `read`'s, cached from now.
  """
  def fetch(key, ttl_ms, read) do
    table = table!()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(table, key) do
      [{^key, value, at}] when now - at < ttl_ms ->
        value

      _ ->
        value = read.()
        :ets.insert(table, {key, value, now})
        value
    end
  end

  @doc "Drops `key`, so the next `fetch/3` reads it again."
  def forget(key) do
    :ets.delete(table!(), key)
    :ok
  end

  defp table! do
    if :ets.whereis(@table) == :undefined,
      do:
        raise(
          "#{inspect(__MODULE__)} is not running; knobs need it: add #{inspect(__MODULE__)} to the application's supervision tree"
        )

    @table
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
