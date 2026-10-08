defmodule __Name__.MixProject do
  use Mix.Project

  def project do
    [app: :__name__, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [mod: {__Name__.Application, []}, extra_applications: [:logger]]

  defp deps do
    [
      {:mana_core, path: "../mana/framework/ash/core"},
      {:moments, path: "../mana/framework/ash/moments"},
      {:contracts, path: "../mana/framework/ash/contracts"},
      {:ash, "~> 3.34 and >= 3.34.3"},
      {:simple_sat, "~> 0.1 and >= 0.1.1"},
      {:ash_postgres, "~> 2.0"},
      {:ash_json_api, "~> 1.0"},
      {:open_api_spex, "~> 3.16"},
      {:phoenix, "~> 1.8.0"},
      {:bandit, "~> 1.0"},
      {:jason, "~> 1.4"}
    ]
  end
end
