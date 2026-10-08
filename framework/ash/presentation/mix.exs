defmodule ManaPresentation.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mana_presentation,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:ash, "~> 3.34 and >= 3.34.3"}, {:jason, "~> 1.4"}, {:ash_json_api, "~> 1.0", optional: true}]
    ]

  def application, do: [extra_applications: [:crypto]]
end
