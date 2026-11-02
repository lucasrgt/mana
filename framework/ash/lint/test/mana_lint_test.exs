defmodule ManaLintTest do
  use ExUnit.Case, async: true

  test "the plugin registers every check, each a Credo check with an explanation" do
    {config, _} = Code.eval_string(ManaLint.config())
    [%{name: "default", checks: %{extra: extra}}] = config.configs

    assert Enum.map(extra, &elem(&1, 0)) == ManaLint.checks()
    assert length(ManaLint.checks()) == 15

    for check <- ManaLint.checks() do
      behaviours =
        check.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      assert Credo.Check in behaviours
      assert check.explanations()[:check] =~ "Instead"
    end
  end

  test "init registers that config as the plugin's default" do
    exec =
      Credo.Execution.build()
      |> Credo.Execution.set_initializing_plugin(ManaLint)
      |> ManaLint.init()

    assert {:plugin, ManaLint, ManaLint.config()} in Credo.Execution.get_config_files(exec)
  end
end
