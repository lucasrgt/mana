defmodule ManaWeb do
  @moduledoc """
  The LiveView adapter of Mana: what each Mana capability looks like on a Phoenix
  LiveView screen. A LiveView calls Ash directly, so it reads the same declarations
  the Flutter adapter receives through the JSON:API contract, with nothing generated.

  `implements/0` lists the capabilities this adapter covers; the catalog's LiveView
  column (`adapters.live` in `framework/catalog.toml`) is held to it by this package's
  tests.
  """

  @implements ~w(errors moments verbs)

  @doc "The catalog ids this adapter implements."
  def implements, do: @implements
end
