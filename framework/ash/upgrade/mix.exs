defmodule ManaUpgrade.MixProject do
  use Mix.Project

  def project do
    [
      app: :mana_upgrade,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:sourceror, "~> 1.10"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mana_lint, path: "../lint", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
