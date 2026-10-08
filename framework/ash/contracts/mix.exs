defmodule Contracts.MixProject do
  use Mix.Project

  def project do
    [
      app: :contracts,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [{:ash, "~> 3.34 and >= 3.34.3"}, {:ash_json_api, "~> 1.0"}, {:open_api_spex, "~> 3.16"}]
    ]
  end

  def application, do: []
end
