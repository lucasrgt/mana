defmodule Mana.Runtime.Probe do
  @moduledoc "Bounded dependency probes using OTP Tasks; saturation means not ready."

  def child_spec(options) do
    name = Keyword.fetch!(options, :name)

    Supervisor.child_spec(
      {Task.Supervisor, name: name, max_children: Keyword.get(options, :max_children, 4)},
      id: name
    )
  end

  @doc "Only a literal true from the probe means ready; timeout/crash/saturation return false."
  def ready?(supervisor, probe, timeout \\ 1_000) when is_function(probe, 0) do
    task = Task.Supervisor.async_nolink(supervisor, probe)

    case Task.yield(task, timeout) do
      {:ok, true} ->
        true

      nil ->
        Task.shutdown(task, 100)
        false

      _ ->
        false
    end
  rescue
    # Task.Supervisor rejects work when its bounded capacity is exhausted.
    RuntimeError -> false
  catch
    :exit, _ -> false
  end
end
