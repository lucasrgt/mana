defmodule ManaWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :mana_web,
      version: "0.1.0",
      elixir: "~> 1.18",
      # Configuration for this package's own test suite; consumers configure their app.
      config_path: "test/config.exs",
      # The tests reuse mana_core's fixture resources.
      elixirc_paths:
        if(Mix.env() == :test,
          do: ["lib", "test/support", Path.expand("../core/test/fixtures", __DIR__)],
          else: ["lib"]
        ),
      deps: [
        {:ash, "~> 3.37 and >= 3.37.2"},
        {:mana_core, path: "../core"},
        {:phoenix_live_view, "~> 1.1"},
        {:moments, path: "../moments"},
        {:lazy_html, ">= 0.1.0"},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mana_lint, path: "../lint", only: [:dev, :test], runtime: false},
        {:simple_sat, "~> 0.1 and >= 0.1.1", only: :test},
        {:ash_json_api, "~> 1.0", only: :test},
        {:toml, "~> 0.7", only: :test}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
