defmodule ManaWeb.CatalogTest do
  # The catalog's LiveView column is what this adapter implements: neither may move alone.
  use ExUnit.Case, async: true

  @catalog Path.expand("../../../catalog.toml", __DIR__)

  defp capabilities, do: Toml.decode_file!(@catalog)["capability"]

  test "every core and primitive capability says where its client half stands" do
    for %{"layer" => layer} = capability <- capabilities(), layer in ["core", "primitive"] do
      case capability["adapters"] do
        "server" ->
          :ok

        %{"flutter" => flutter, "live" => live} ->
          assert valid?(flutter), "#{capability["id"]}: flutter #{inspect(flutter)}"
          assert valid?(live), "#{capability["id"]}: live #{inspect(live)}"

        other ->
          flunk("#{capability["id"]}: adapters #{inspect(other)}")
      end
    end
  end

  test "the catalog says available in LiveView exactly for what mana_web implements" do
    available =
      for %{"adapters" => %{"live" => "available"}, "id" => id} <- capabilities(), do: id

    assert Enum.sort(available) == Enum.sort(ManaWeb.implements())
  end

  defp valid?(status) when status in ["available", "planned"], do: true
  defp valid?(%{"not_applicable" => why}) when is_binary(why) and why != "", do: true
  defp valid?(_status), do: false
end
