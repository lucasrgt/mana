defmodule Moments.MixProject do
  use Mix.Project

  def project do
    # Tests declare resources after compilation; protocols stay open for them.
    [
      app: :moments,
      version: "0.1.0",
      elixir: "~> 1.18",
      consolidate_protocols: Mix.env() != :test,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
  # Verb steps read `Mana.Verbs` when the consumer has it; tests declare verbs with it.
  defp deps,
    do: [
      {:ash, "~> 3.34 and >= 3.34.3"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:mana_core, path: "../core", only: :test},
      {:ecto_sql, "~> 3.12", only: :test},
      {:postgrex, "~> 0.20", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:simple_sat, "~> 0.1 and >= 0.1.1", only: :test}
    ]
end
