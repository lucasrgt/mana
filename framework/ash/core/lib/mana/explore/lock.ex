defmodule Mana.Explore.Lock do
  @moduledoc """
  The affordance graph of an exploration as a file committed with the code
  (`affordances.json`): per resource, per shape, per actor, the verbs
  offered there. A pull request that changes what people may do shows it
  as a diff of this file, and `diff/2` reads it as sentences:

      `cancel` is no longer offered to host on booking when status=paid

  The exploration is seeded and orders records by what they hold, so the
  same code writes the same bytes, however the store orders ties; a change
  in what inputs are generated can still move which shapes are reached,
  and then the diff says so (a shape newly or no longer reached).
  """

  @doc "The lock of `report`."
  def build(%Mana.Explore.Report{} = report) do
    resources =
      Enum.reduce(report.affordances, %{}, fn {{type, shape}, entry}, acc ->
        actors =
          for {actor, counts} <- entry, actor != :seen, into: %{} do
            {to_string(actor), counts |> Map.keys() |> Enum.sort()}
          end

        Map.update(acc, type, %{shape => actors}, &Map.put(&1, shape, actors))
      end)

    %{"version" => 1, "seed" => report.seed, "runs" => report.runs, "resources" => resources}
  end

  @doc "`lock` as stable, pretty JSON."
  def encode(lock), do: lock |> ordered() |> Jason.encode!(pretty: true) |> Kernel.<>("\n")

  defp ordered(map) when is_map(map),
    do:
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> {k, ordered(v)} end)
      |> Jason.OrderedObject.new()

  defp ordered(list) when is_list(list), do: Enum.map(list, &ordered/1)
  defp ordered(value), do: value

  @doc "What changed from lock `old` to lock `new`, as sentences a person reads."
  def diff(old, new) do
    old = Map.get(old, "resources", %{})
    new = Map.get(new, "resources", %{})

    for type <- Enum.sort(Enum.uniq(Map.keys(old) ++ Map.keys(new))),
        shapes_old = Map.get(old, type, %{}),
        shapes_new = Map.get(new, type, %{}),
        shape <- Enum.sort(Enum.uniq(Map.keys(shapes_old) ++ Map.keys(shapes_new))),
        sentence <-
          shape_diff(type, shape, Map.get(shapes_old, shape), Map.get(shapes_new, shape)),
        do: sentence
  end

  defp shape_diff(type, shape, nil, _new), do: ["#{where(type, shape)} is newly reached"]
  defp shape_diff(type, shape, _old, nil), do: ["#{where(type, shape)} is no longer reached"]

  defp shape_diff(type, shape, old, new) do
    for actor <- Enum.sort(Enum.uniq(Map.keys(old) ++ Map.keys(new))),
        before = MapSet.new(Map.get(old, actor, [])),
        now = MapSet.new(Map.get(new, actor, [])),
        sentence <-
          Enum.map(
            Enum.sort(MapSet.difference(before, now)),
            &"`#{&1}` is no longer offered to #{actor} on #{where(type, shape)}"
          ) ++
            Enum.map(
              Enum.sort(MapSet.difference(now, before)),
              &"`#{&1}` is now offered to #{actor} on #{where(type, shape)}"
            ),
        do: sentence
  end

  defp where(type, ""), do: type
  defp where(type, shape), do: "#{type} when #{String.replace(shape, ",", ", ")}"
end
