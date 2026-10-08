defmodule Mana.BRTest do
  use ExUnit.Case, async: true

  test "documents keep only valid check digits" do
    assert {:ok, "52998224725"} = Ash.Type.cast_input(Mana.BR.Cpf, "529.982.247-25", [])
    assert {:error, _} = Ash.Type.cast_input(Mana.BR.Cpf, "529.982.247-24", [])
    assert {:error, _} = Ash.Type.cast_input(Mana.BR.Cpf, "111.111.111-11", [])
    assert {:ok, "11222333000181"} = Ash.Type.cast_input(Mana.BR.Cnpj, "11.222.333/0001-81", [])
    assert {:error, _} = Ash.Type.cast_input(Mana.BR.Cnpj, "11.222.333/0001-80", [])
  end

  test "plates, phones and CEPs are canonical" do
    assert {:ok, "ABC1D23"} = Ash.Type.cast_input(Mana.BR.Plate, "abc-1d23", [])
    assert {:ok, "ABC1234"} = Ash.Type.cast_input(Mana.BR.Plate, "ABC 1234", [])
    assert {:error, _} = Ash.Type.cast_input(Mana.BR.Plate, "AB1234", [])
    assert {:ok, "11987654321"} = Ash.Type.cast_input(Mana.BR.Phone, "+55 (11) 98765-4321", [])
    assert {:error, _} = Ash.Type.cast_input(Mana.BR.Phone, "0119876543", [])
    assert {:ok, "01310100"} = Ash.Type.cast_input(Mana.BR.Cep, "01310-100", [])
  end

  test "each type publishes the br-* format its client half recognizes" do
    for {type, format} <- [
          {Mana.BR.Cpf, "br-cpf"},
          {Mana.BR.Cnpj, "br-cnpj"},
          {Mana.BR.Cep, "br-cep"},
          {Mana.BR.Phone, "br-phone"},
          {Mana.BR.Plate, "br-plate"}
        ] do
      assert type.format() == format
      assert type.json_write_schema([]) == %{"type" => "string", "format" => format}
    end
  end
end
