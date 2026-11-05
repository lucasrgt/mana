# mix run differential/cases.exs gen <dir>      writes <dir>/cases.txt and <dir>/expected.txt
# mix run differential/cases.exs compare <dir>  compares <dir>/actual.txt (from C#) with expected.txt
alias Mop.Money.Split

defmodule Cases do
  @seed {1, 2, 3}

  def families do
    :rand.seed(:exsss, @seed)

    [
      {"realistic", for(_ <- 1..10_000, do: realistic())},
      {"small", for(_ <- 1..2_000, do: small())},
      {"decimal_precision", for(_ <- 1..200, do: precision())},
      {"decimal_overflow", for(_ <- 1..50, do: overflow())}
    ]
  end

  # Up to 12 installments of up to R$ 100,000.00; a total up to twice the plan.
  defp realistic do
    values = for _ <- 1..:rand.uniform(12), do: :rand.uniform(10_000_000)
    {:rand.uniform(2 * Enum.sum(values)), values}
  end

  defp small do
    values = for _ <- 1..:rand.uniform(6), do: :rand.uniform(5)
    {:rand.uniform(50), values}
  end

  # Three installments where the second one's value * total / source sits 1/source below an integer. The product
  # still fits in a decimal (about 7.9e28), but the quotient with its fraction needs more than
  # the 28-29 significant digits a decimal holds, so the division has to round.
  defp precision do
    source = 30_000_000_000_000 + :rand.uniform(1_000_000_000) * 2 + 1
    value = coprime(source)
    inverse = inverse(value, source)
    total = Integer.mod(-inverse, source) + source * (60 + :rand.uniform(10))
    {total, [1, value, source - value - 1]}
  end

  # value * total beyond decimal's range of about 7.9e28.
  defp overflow do
    values = for _ <- 1..2, do: 1_000_000_000_000_000 + :rand.uniform(1_000_000_000)
    {1_000_000_000_000_000 + :rand.uniform(1_000_000_000), values}
  end

  defp coprime(source) do
    value = div(source, 2) + :rand.uniform(1_000_000)
    if Integer.gcd(value, source) == 1, do: value, else: coprime(source)
  end

  defp inverse(a, m), do: Integer.mod(egcd(a, m) |> elem(1), m)
  defp egcd(a, 0), do: {a, 1, 0}

  defp egcd(a, b) do
    {g, x, y} = egcd(b, rem(a, b))
    {g, y, x - div(a, b) * y}
  end

  def line({total, values}), do: "#{total};#{Enum.join(values, ",")}"
  def expected({total, values}), do: Enum.join(Split.rescale(values, total), ",")
end

case System.argv() do
  ["gen", dir] ->
    cases = Enum.flat_map(Cases.families(), &elem(&1, 1))
    File.write!(Path.join(dir, "cases.txt"), Enum.map_join(cases, "", &(Cases.line(&1) <> "\n")))
    File.write!(Path.join(dir, "expected.txt"), Enum.map_join(cases, "", &(Cases.expected(&1) <> "\n")))
    IO.puts("#{length(cases)} cases")

  ["compare", dir] ->
    actual = File.read!(Path.join(dir, "actual.txt")) |> String.split("\n", trim: true)
    expected = File.read!(Path.join(dir, "expected.txt")) |> String.split("\n", trim: true)
    families = Cases.families()
    labels = Enum.flat_map(families, fn {name, cases} -> Enum.map(cases, &{name, &1}) end)

    for {name, _} <- families do
      rows =
        Enum.zip([labels, actual, expected])
        |> Enum.filter(fn {{family, _}, _, _} -> family == name end)

      diverging = Enum.filter(rows, fn {_, a, e} -> a != e end)
      IO.puts("#{name}: #{length(rows) - length(diverging)}/#{length(rows)} agree")

      for {{_, c}, a, e} <- Enum.take(diverging, 2) do
        IO.puts("  case     #{Cases.line(c)}")
        IO.puts("  C#       #{a}")
        IO.puts("  Elixir   #{e}")
      end
    end
end
