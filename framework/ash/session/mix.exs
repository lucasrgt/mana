defmodule ManaSession.MixProject do
  use Mix.Project

  def project do
    [
      app: :mana_session,
      version: "0.1.0",
      elixir: "~> 1.18",
      deps: [
        {:contracts, path: "../contracts"},
        {:ash_authentication, "~> 4.15.0"},
        {:ash_postgres, "~> 2.0"},
        {:plug, "~> 1.18"},
        {:jason, "~> 1.4"}
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
