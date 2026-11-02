# Credo's default checks, strict, plus Mana's (ManaLint); mana doctor refuses
# a check switched off here or a finding silenced in the code. A ManaLint check
# is tuned with its params, never turned off.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      plugins: [{ManaLint, []}],
      strict: true
    }
  ]
}
