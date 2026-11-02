defmodule ManaRuntime.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mana_runtime,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:plug, "~> 1.18"},
        {:telemetry_metrics, "~> 1.1"},
        {:peep, "~> 5.0"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mana_lint, path: "../lint", only: [:dev, :test], runtime: false}
      ]
    ]

  def application, do: [extra_applications: [:ssl]]
end
