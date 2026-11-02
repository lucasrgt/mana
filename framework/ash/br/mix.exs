defmodule ManaBr.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mana_br,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:ash, "~> 3.37 and >= 3.37.2"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mana_lint, path: "../lint", only: [:dev, :test], runtime: false}
      ]
    ]

  def application, do: [extra_applications: [:logger]]
end
