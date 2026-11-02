defmodule ManaLint.Check.BroadRescueTest do
  use Credo.Test.Case

  alias ManaLint.Check.BroadRescue, as: Check

  test "rescue _ and catch _, _ that swallow" do
    """
    defmodule App.Verbs do
      def offered?(resource, actor) do
        Ash.can?({resource, :update}, actor)
      rescue
        _ -> false
      end

      def repair(record) do
        try do
          App.Repair.run(record)
        catch
          _kind, _reason -> :skipped
        end
      end
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() == ["_", "_kind"]
    end)
  end

  test "specific rescues, kept errors, reraise and reports are fine" do
    """
    defmodule App.Fine do
      require Logger

      def a(x), do: String.to_integer(x)
      rescue
        ArgumentError -> nil

      def b(f) do
        f.()
      rescue
        e -> {:error, e}
      end

      def c(f) do
        f.()
      rescue
        _ ->
          Logger.error("c failed")
          nil
      end

      def d(f) do
        try do
          f.()
        rescue
          _ -> report_failure(f)
        catch
          :exit, _ -> :exited
        end
      end

      def e(f) do
        f.()
      rescue
        _ -> warn_and_nil()
      end

      defp report_failure(_), do: :ok
      defp warn_and_nil, do: :telemetry.execute([:app, :failed], %{}, %{})
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end

  test "tests asserting a failure may catch everything" do
    "defmodule T do\n  def t(f), do: f.()\n  rescue\n    _ -> :raised\nend\n"
    |> to_source_file("test/app/t_test.exs")
    |> run_check(Check)
    |> refute_issues()
  end
end
