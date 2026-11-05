defmodule Mana.Router do
  @moduledoc "Derives transport facts from the resources' `access` declarations."

  @doc "The `{method, path_info}` patterns of public AshJsonApi routes under `prefix`."
  def public_routes(domains, prefix) do
    prefix = String.split(prefix, "/", trim: true)

    for domain <- domains,
        route <- AshJsonApi.Domain.Info.routes(domain),
        Mana.Resource.Info.public?(route.resource, route.action) do
      {route.method |> to_string() |> String.upcase(),
       prefix ++ String.split(route.route, "/", trim: true)}
    end
  end

  @doc "Whether `conn`'s method and path match one of the given patterns (`:param` segments match any)."
  def match?(%{method: method, path_info: path}, patterns) do
    Enum.any?(patterns, fn {m, pattern} ->
      m == method and length(pattern) == length(path) and
        Enum.all?(Enum.zip(pattern, path), fn {p, s} -> String.starts_with?(p, ":") or p == s end)
    end)
  end
end
