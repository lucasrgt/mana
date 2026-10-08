defmodule Mana.Runtime.ProbeTest do
  use ExUnit.Case, async: true
  alias Mana.Runtime.Probe

  test "a stalled dependency cannot retain the request or its worker" do
    supervisor = start_supervised!({Probe, name: __MODULE__, max_children: 1})
    assert Probe.ready?(supervisor, fn -> true end)
    refute Probe.ready?(supervisor, fn -> :unexpected end)
    began = System.monotonic_time(:millisecond)
    refute Probe.ready?(supervisor, fn -> receive do: (:never -> true) end, 30)
    assert System.monotonic_time(:millisecond) - began < 1_000
    assert Task.Supervisor.children(supervisor) == []
    assert Probe.ready?(supervisor, fn -> true end)
  end

  test "saturation refuses extra work without killing the caller" do
    supervisor = start_supervised!({Probe, name: __MODULE__.Busy, max_children: 1})
    {:ok, worker} = Task.Supervisor.start_child(supervisor, fn -> receive do: (:never -> :ok) end)
    refute Probe.ready?(supervisor, fn -> true end)
    assert Task.Supervisor.children(supervisor) == [worker]
    Task.Supervisor.terminate_child(supervisor, worker)
    assert Probe.ready?(supervisor, fn -> true end)
  end
end
