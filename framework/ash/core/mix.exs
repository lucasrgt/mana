defmodule ManaCore.MixProject do
  use Mix.Project

  def project,
    do: [
      app: :mana_core,
      version: "0.1.0",
      elixir: "~> 1.18",
      consolidate_protocols: Mix.env() != :test,
      deps: [{:ash, "~> 3.34 and >= 3.34.3"}, {:ash_json_api, "~> 1.0", optional: true}, {:oban, "~> 2.24", optional: true},
        {:req, "~> 0.5", optional: true},
        {:req_s3, "~> 0.2", optional: true},
        {:plug, "~> 1.16", optional: true},
        {:phoenix, "~> 1.7", optional: true},
        {:open_api_spex, "~> 3.16", optional: true},
        {:vix, "~> 0.35", optional: true}
      ]
    ]

  def application, do: [extra_applications: [:logger]]
end
