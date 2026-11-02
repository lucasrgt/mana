defmodule ManaSession.MixProject do
  use Mix.Project

  def project do
    [
      app: :mana_session,
      version: "0.1.0",
      elixir: "~> 1.18",
      # Configuration for this package's own test suite; consumers configure their app.
      config_path: "test/config.exs",
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: [
        {:contracts, path: "../contracts"},
        {:ash_authentication, "~> 4.15.0"},
        {:ash_postgres, "~> 2.15 and >= 2.15.2"},
        {:plug, "~> 1.18"},
        {:jason, "~> 1.4"},
        # EEF-CVE-2026-117656 is fixed in assent 0.3.2; AshAuthentication 4.15.0 caps it below 0.3.
        {:assent, "~> 0.3.2", override: true},
        {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
        {:mana_lint, path: "../lint", only: [:dev, :test], runtime: false}
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto]]
end
