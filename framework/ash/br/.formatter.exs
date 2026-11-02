# The DSLs keep the calls without parentheses they allow.
[
  import_deps: [:ash, :spark],
  inputs: ["mix.exs", "{config,lib,test,tool}/**/*.{ex,exs}"]
]
