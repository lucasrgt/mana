defmodule ContractsTest.Stamped do
  @moduledoc "A consumer's modifier: normalizes, then adds its own operations."
  def modify(spec, conn, opts),
    do: spec |> Contracts.OpenApi.modify(conn, opts) |> put_in(["paths", "/auth/ping"], %{})
end

defmodule ContractsTest.NoModify do
  @moduledoc false
  def modify(spec), do: spec
end

defmodule Mix.Tasks.Contracts.ExportTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Contracts.Export

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    directory = Path.join(System.tmp_dir!(), "contracts-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Mix.shell(shell)
      File.rm_rf!(directory)
    end)

    %{output: Path.join([directory, "nested", "openapi.json"])}
  end

  defp read(output), do: output |> File.read!() |> Jason.decode!()

  test "writes the normalized contract, creating its folder, and says where", %{output: output} do
    Export.run(["ContractsTest.Notes", "/api", output])

    text = File.read!(output)
    assert String.ends_with?(text, "}\n")
    contract = Jason.decode!(text)

    assert contract ==
             [domains: [ContractsTest.Notes], prefix: "/api"]
             |> AshJsonApi.OpenApi.spec()
             |> Contracts.OpenApi.modify(nil, [])

    assert Map.keys(contract["paths"]) |> Enum.all?(&String.starts_with?(&1, "/api/"))
    refute File.exists?(output <> ".tmp")
    assert_received {:mix_shell, :info, ["Exported contract to " <> ^output]}
  end

  test "several domains, comma-separated, share one contract", %{output: output} do
    Export.run(["ContractsTest.Notes,ContractsTest.Tags", "/v1", output])

    paths = Map.keys(read(output)["paths"])
    assert "/v1/notes" in paths
    assert "/v1/tags" in paths
  end

  test "a fourth argument names the modifier that replaces the default", %{output: output} do
    Export.run(["ContractsTest.Notes", "/api", output, "ContractsTest.Stamped"])

    contract = read(output)
    assert contract["paths"]["/auth/ping"] == %{}
    assert Map.has_key?(contract["paths"], "/api/notes")
  end

  test "an export that fails leaves the previous contract in place", %{output: output} do
    Export.run(["ContractsTest.Notes", "/api", output])
    before = File.read!(output)

    assert_raise Mix.Error, ~r/must export modify\/3/, fn ->
      Export.run(["ContractsTest.Notes", "/api", output, "ContractsTest.NoModify"])
    end

    assert_raise Mix.Error, ~r/Prefix must start with \//, fn ->
      Export.run(["ContractsTest.Notes", "api", output])
    end

    assert File.read!(output) == before
  end

  test "a wrong number of arguments prints the usage" do
    for args <- [[], ["ContractsTest.Notes"], ["a", "/b", "c", "D", "e"]] do
      assert_raise Mix.Error, ~r/^Usage: mix contracts.export/, fn -> Export.run(args) end
    end
  end
end
