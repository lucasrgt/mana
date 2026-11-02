# The DSLs keep the calls without parentheses they allow.
[
  import_deps: [:ash, :spark, :ash_postgres, :ash_authentication, :plug],
  inputs: ["mix.exs", "{config,lib,test,tool}/**/*.{ex,exs}"]
]
