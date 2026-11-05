# The DSLs keep the calls without parentheses they allow.
[
  import_deps: [:ash, :spark, :phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["mix.exs", "{config,lib,test}/**/*.{ex,exs,heex}"]
]
