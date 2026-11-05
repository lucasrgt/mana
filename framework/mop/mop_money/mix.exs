defmodule Mop.Money.MixProject do
  use Mix.Project

  def project do
    [
      app: :mop_money,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:lynx,
       git: "https://github.com/josevalim/lynx.git",
       ref: "0bd83e0cdb7d4081ac2ae49e9bde62d6eb50cbdc",
       only: :test}
    ]
  end
end
