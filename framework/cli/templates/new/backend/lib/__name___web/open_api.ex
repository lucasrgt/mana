defmodule __Name__Web.OpenApi do
  @moduledoc "The JSON:API contract with Mana's declarations on each resource (verbs, views, notices…)."

  def modify(spec, conn, options) do
    spec
    |> Contracts.OpenApi.modify(conn, options)
    |> Mana.Domain.OpenApi.finish(Application.fetch_env!(:__name__, :ash_domains))
  end
end
