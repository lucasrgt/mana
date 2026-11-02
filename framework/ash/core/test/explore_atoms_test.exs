defmodule Mana.ExploreAtomsTest do
  use ExUnit.Case, async: true

  test "a saved trace naming an actor no one declared is refused without minting an atom" do
    name = "nobody_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{name}.json")
    on_exit(fn -> File.rm(path) end)
    File.write!(path, Jason.encode!(%{"moves" => [%{"kind" => "start", "actor" => name}]}))

    assert_raise ArgumentError, fn -> Mana.Explore.replay_file(path, [], %{}) end
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end
end
