defmodule Moments.MixProject do
  use Mix.Project

  def project do
    [app: :moments, version: "0.1.0", elixir: "~> 1.18", deps: deps()]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
  defp deps, do: [{:ash, "~> 3.34 and >= 3.34.3"}, {:jason, "~> 1.4"}, {:plug, "~> 1.16"}]
end
