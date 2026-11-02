defmodule Mana.Notifications.Groups do
  @moduledoc """
  Owns the table `group_within` (`Mana.Notifications`) counts repeats in,
  and drops the windows that closed every `sweep_every` ms (60 000). Start
  it in the application's supervision tree:

      children = [Mana.Notifications.Groups, ...]

  While it is not running, an action whose resource declares `group_within`
  and sends a notice is refused before it writes anything, with an error
  naming this module.
  """
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def started?, do: :ets.whereis(@table) != :undefined

  @doc false
  def not_running,
    do:
      "#{inspect(__MODULE__)} is not running; group_within needs it: add #{inspect(__MODULE__)} to the application's supervision tree"

  @doc """
  Counts one more notice under `key` and answers how many its window holds
  now: 1 opens a window of `window_ms`, more is a repeat inside it.
  """
  def count(key, window_ms, now \\ System.system_time(:millisecond)) do
    unless started?(), do: raise(not_running())

    # A binary key keeps the match specs below a key lookup: a map in a match
    # head is a pattern, not a value.
    key = :erlang.term_to_binary(key, [:deterministic])

    # Each step is one atomic table operation, so notices racing for the same
    # window get distinct counts and only one of them is sent in full.
    cond do
      :ets.insert_new(@table, {key, now + window_ms, now, 1}) -> 1
      reopen(key, window_ms, now) -> 1
      true -> :ets.update_counter(@table, key, {4, 1}, {key, now + window_ms, now, 0})
    end
  end

  defp reopen(key, window_ms, now) do
    closed = [
      {{key, :_, :"$1", :_}, [{:"=<", :"$1", now - window_ms}],
       [{{key, now + window_ms, now, 1}}]}
    ]

    :ets.select_replace(@table, closed) == 1
  end

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    every = Keyword.get(opts, :sweep_every, 60_000)
    Process.send_after(self(), :sweep, every)
    {:ok, every}
  end

  # Rows are {key, closes_at, opened_at, count}.
  @impl true
  def handle_info(:sweep, every) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :"$1", :_, :_}, [{:<, :"$1", now}], [true]}])
    Process.send_after(self(), :sweep, every)
    {:noreply, every}
  end
end
