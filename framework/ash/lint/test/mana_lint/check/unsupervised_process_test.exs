defmodule ManaLint.Check.UnsupervisedProcessTest do
  use Credo.Test.Case

  alias ManaLint.Check.UnsupervisedProcess, as: Check

  test "spawn, Task.start, register in rescue and sleep" do
    """
    defmodule App.Groups do
      def ensure do
        spawn(fn -> own() end)
        Task.start(fn -> :ok end)
      end

      defp own do
        Process.register(self(), __MODULE__)
      rescue
        ArgumentError ->
          Process.sleep(5)
          own()
      end
    end
    """
    |> to_source_file("lib/app/groups.ex")
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() ==
               ["Process.register", "Process.sleep", "Task.start", "spawn"]
    end)
  end

  test "supervised tasks, links under a supervisor, interventions, fakes and tests are fine" do
    """
    defmodule App.Work do
      def run(fun), do: Task.Supervisor.start_child(App.Tasks, fun)
      def child, do: Task.start_link(fn -> :ok end)
      def register, do: Process.register(self(), :app_work)
    end

    defmodule App.Intervene.Latency do
      def apply(ms), do: Process.sleep(ms)
    end

    defmodule App.Payments.Fake do
      def slow, do: :timer.sleep(10)
    end
    """
    |> to_source_file("lib/app/work.ex")
    |> run_check(Check)
    |> refute_issues()

    "defmodule T do\n  def t, do: spawn(fn -> Process.sleep(1) end)\nend\n"
    |> to_source_file("test/app/t_test.exs")
    |> run_check(Check)
    |> refute_issues()
  end
end
