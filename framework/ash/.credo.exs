# Credo for every Mana package, read from this parent directory: the default
# checks, strict.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true
    }
  ]
}
