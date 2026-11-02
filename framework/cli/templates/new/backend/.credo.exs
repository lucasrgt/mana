# Credo's default checks, strict; mana doctor refuses a check switched off
# here or a finding silenced in the code.
%{
  configs: [
    %{
      name: "default",
      files: %{included: ["lib/", "test/", "config/", "mix.exs"], excluded: [~r"/_build/", ~r"/deps/"]},
      strict: true
    }
  ]
}
