defmodule ManaBr.MixProject do
  use Mix.Project

  def project,
    do: [app: :mana_br, version: "0.1.0", elixir: "~> 1.18", deps: [{:ash, "~> 3.34 and >= 3.34.3"}]]

  def application, do: [extra_applications: [:logger]]
end
