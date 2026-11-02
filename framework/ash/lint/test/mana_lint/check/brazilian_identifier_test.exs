defmodule ManaLint.Check.BrazilianIdentifierTest do
  use Credo.Test.Case

  alias ManaLint.Check.BrazilianIdentifier, as: Check

  test "an identifier validated, masked or matched by hand" do
    ~S"""
    defmodule App.Documents do
      def valid_cpf?(cpf) when is_binary(cpf), do: cpf =~ ~r/^\d{3}\.?\d{3}\.?\d{3}-?\d{2}$/
      def valid_cpf?(_), do: false

      def format_cep(cep), do: String.replace(cep, ~r/^(\d{5})(\d{3})$/, "\\1-\\2")
      def cnpj_valid?(cnpj), do: cnpj =~ ~r/\d{2}\.?\d{3}\.?\d{3}\/?\d{4}-?\d{2}/
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> assert_issues(fn issues ->
      assert issues |> Enum.map(& &1.trigger) |> Enum.sort() ==
               ["cnpj_valid?", "format_cep", "valid_cpf?", "~r", "~r", "~r"]
    end)
  end

  test "Mana.BR, and code that only names identifiers, are left alone" do
    ~S"""
    defmodule Mana.BR do
      def cpf?(digits), do: digits =~ ~r/^\d{11}$/
      def format_cpf(digits), do: digits
    end

    defmodule App.People do
      def with_cpf(person), do: Map.take(person, [:cpf])
      def code(value), do: value =~ ~r/^\d{4}$/
    end
    """
    |> to_source_file()
    |> run_check(Check)
    |> refute_issues()
  end
end
