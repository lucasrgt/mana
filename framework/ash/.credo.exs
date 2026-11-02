# Credo for every Mana package, read from this parent directory: the default
# checks, strict, plus Mana's own (ManaLint, from ./lint). Each package loads
# the plugin as a dev/test path dependency; `mix credo` compiles it first.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      plugins: [{ManaLint, []}],
      strict: true
    }
  ]
}
