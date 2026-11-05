defmodule Mop.Proof do
  @moduledoc """
  Joins Lean fragments into one proof, so a lemma is written once and spliced into every law
  that needs it. Diagnostics point at the last fragment.

  It belongs to the `mop` core package; it lives here until that package exists.
  """
  def join(fragments) do
    last = List.last(fragments)
    %{last | source: Enum.map_join(fragments, "\n", & &1.source)}
  end
end
