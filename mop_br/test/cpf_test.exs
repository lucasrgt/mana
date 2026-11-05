defmodule Mop.Br.CpfTest do
  use ExUnit.Case, async: true

  alias Mop.Br.Cpf

  test "accepts a valid CPF and refuses a wrong check digit" do
    assert Cpf.valid?("52998224725")
    refute Cpf.valid?("52998224726")
  end

  test "refuses equal digits, punctuation, letters and wrong lengths" do
    refute Cpf.valid?("11111111111")
    refute Cpf.valid?("529.982.247-25")
    refute Cpf.valid?("5299822472A")
    refute Cpf.valid?("5299822472")
    refute Cpf.valid?(nil)
  end
end
