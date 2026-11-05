defmodule Mop.Br.CnpjTest do
  use ExUnit.Case, async: true

  alias Mop.Br.Cnpj

  test "accepts the Receita Federal's alphanumeric example 12.ABC.345/01DE-35" do
    assert Cnpj.valid?("12ABC34501DE35")
    assert Cnpj.check_digits(~c"12ABC34501DE") == ~c"35"
  end

  test "keeps accepting numeric CNPJs" do
    assert Cnpj.valid?("11222333000181")
    refute Cnpj.valid?("11222333000182")
  end

  test "rejects equal characters, lowercase, punctuation and wrong lengths" do
    refute Cnpj.valid?("00000000000000")
    refute Cnpj.valid?("12abc34501de35")
    refute Cnpj.valid?("12.ABC.345/01DE-35")
    refute Cnpj.valid?("12ABC34501DE3")
    refute Cnpj.valid?(nil)
  end

  test "the official rule cannot tell 6 from A, 7 from B, 8 from C or 9 from D" do
    # Both characters are worth 11 apart (54 - 48 = 6, 65 - 48 = 17), and every
    # weight multiplies that difference into a multiple of 11.
    base = ~c"1234567890AB"
    swapped = Enum.map(base, fn code -> if code == ?6, do: ?A, else: code end)

    assert Cnpj.check_digits(base) == Cnpj.check_digits(swapped)
    assert Cnpj.valid_codes?(base ++ Cnpj.check_digits(base))
    assert Cnpj.valid_codes?(swapped ++ Cnpj.check_digits(base))
  end
end
