defmodule ManaLint.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mana_lint,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:credo, "~> 1.7"}]
    ]

  def application, do: [extra_applications: [:logger]]
end
