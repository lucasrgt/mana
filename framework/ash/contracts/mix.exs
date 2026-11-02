defmodule Contracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :contracts,
      version: "0.1.0",
      elixir: "~> 1.18",
      # Configuration for this package's own test suite; consumers configure their app.
      config_path: "test/config.exs",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [
        {:ash, "~> 3.37 and >= 3.37.2"},
        {:ash_json_api, "~> 1.0"},
        {:open_api_spex, "~> 3.16"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mana_lint, path: "../lint", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application, do: []
end
