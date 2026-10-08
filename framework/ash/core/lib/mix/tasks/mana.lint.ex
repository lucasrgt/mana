defmodule Mix.Tasks.Mana.Lint do
  @shortdoc "Reports code that reimplements a Mana primitive"
  @moduledoc """
  Scans the app's `lib/` for what a Mana primitive already does and names the
  primitive to use instead — the Elixir half of the Dart `mana_use_primitives`
  lint, from the same catalog:

      mix mana.lint [paths...]

  A line that must stay as it is carries `mana:allow <why>` in a comment, on
  it or on the line above.
  Exits with status 1 when something is reported.
  """
  use Mix.Task

  @idioms [
    %{
      what: "a broadcast of record changes",
      use: "Mana.Entity (the record announces its own changes on entity:<type>:<id>)",
      pattern: ~r/(PubSub\.broadcast|Endpoint\.broadcast)\(/
    },
    %{
      what: "a job scheduled for a record's date",
      use: "a Mana.Entity deadline (deadline :name, action:, when:, at: or after:)",
      pattern: ~r/Oban\.insert[!(].*scheduled_at|schedule_in:/
    },
    %{
      what: "a notice sent by hand",
      use: "a declared notify in the resource's notifications (Mana.Notifications)",
      pattern: ~r/Notifications\.notify!?\(/
    },
    %{
      what: "a Brazilian identifier (CPF, CNPJ, CEP, phone or plate)",
      use: "Mana.BR",
      pattern: ~r/def (valid|format|mask|normalize|parse)_?\w*(cpf|cnpj|cep|plate)|\\d\{3\}\\?\.?\\d\{3\}\\?\.?\\d\{3\}|\\d\{5\}-\??\\d\{3\}/i
    }
  ]

  @impl true
  def run(args) do
    findings = args |> paths() |> Enum.flat_map(&scan/1)

    for {file, line, idiom} <- findings do
      Mix.shell().info("#{file}:#{line}: reimplements #{idiom.what}; use #{idiom.use}")
    end

    if findings == [] do
      Mix.shell().info("mana.lint: nothing reimplements a Mana primitive")
    else
      exit({:shutdown, 1})
    end
  end

  @doc false
  def idioms, do: @idioms

  @doc false
  def scan(file) do
    lines = file |> File.read!() |> String.split("\n")

    [nil | lines]
    |> Enum.zip(lines)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {{previous, text}, line} ->
      if String.contains?(text, "mana:allow") or String.contains?(previous || "", "mana:allow"),
        do: [],
        else: for(idiom <- @idioms, Regex.match?(idiom.pattern, text), do: {file, line, idiom})
    end)
  end

  defp paths([]), do: Path.wildcard("lib/**/*.ex")
  defp paths(args), do: Enum.flat_map(args, &if(File.dir?(&1), do: Path.wildcard(Path.join(&1, "**/*.ex")), else: [&1]))
end
