defmodule Mana.BR do
  @moduledoc """
  Brazilian identifiers as Ash types. Each accepts formatted input, stores the
  canonical form (digits; plates uppercase) and rejects invalid documents with the
  official check digits. Kept out of `mana_core`: a country's scalars are not core.
  """

  @doc "Valid CPF (11 digits, mod-11 check digits, not all equal)."
  def cpf?(digits) when byte_size(digits) == 11,
    do: digits =~ ~r/^\d{11}$/ and not same?(digits) and check(digits, 9, Enum.to_list(10..2//-1)) and check(digits, 10, Enum.to_list(11..2//-1))

  def cpf?(_), do: false

  @doc "Valid CNPJ (14 digits, mod-11 check digits, not all equal)."
  def cnpj?(digits) when byte_size(digits) == 14,
    do:
      digits =~ ~r/^\d{14}$/ and not same?(digits) and check(digits, 12, [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]) and
        check(digits, 13, [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2])

  def cnpj?(_), do: false

  @doc "A legacy (ABC1234) or Mercosul (ABC1D23) plate."
  def plate?(plate), do: plate =~ ~r/^[A-Z]{3}[0-9]{4}$/ or plate =~ ~r/^[A-Z]{3}[0-9][A-Z][0-9]{2}$/

  def digits(value), do: String.replace(to_string(value), ~r/\D/, "")

  def plate(value), do: to_string(value) |> String.replace(~r/[^[:alnum:]]/u, "") |> String.upcase()

  @doc "A Brazilian phone without the country code: DDD + 8 or 9 digits."
  def phone(value) do
    digits = digits(value)
    digits = if byte_size(digits) in [12, 13] and String.starts_with?(digits, "55"), do: binary_part(digits, 2, byte_size(digits) - 2), else: digits
    if byte_size(digits) in [10, 11] and not String.starts_with?(digits, "0"), do: {:ok, digits}, else: :error
  end

  @doc false
  def cast_cpf(value), do: value |> digits() |> then(&if(cpf?(&1), do: {:ok, &1}, else: :error))
  @doc false
  def cast_cnpj(value), do: value |> digits() |> then(&if(cnpj?(&1), do: {:ok, &1}, else: :error))
  @doc false
  def cast_cep(value), do: value |> digits() |> then(&if(byte_size(&1) == 8, do: {:ok, &1}, else: :error))
  @doc false
  def cast_plate(value), do: value |> plate() |> then(&if(plate?(&1), do: {:ok, &1}, else: :error))

  defp same?(digits), do: digits |> String.graphemes() |> Enum.uniq() |> length() == 1

  defp check(digits, position, weights) do
    sum = weights |> Enum.with_index() |> Enum.reduce(0, fn {w, i}, acc -> acc + String.to_integer(binary_part(digits, i, 1)) * w end)
    remainder = rem(sum, 11)
    expected = if remainder < 2, do: 0, else: 11 - remainder
    String.to_integer(binary_part(digits, position, 1)) == expected
  end
end

defmodule Mana.BR.Type do
  @moduledoc false
  defmacro __using__(opts) do
    quote do
      use Ash.Type
      @normalize unquote(opts[:normalize])
      @message unquote(opts[:message])
      @format unquote(opts[:format])

      @doc "The OpenAPI `format` the client half (`mana_br`) recognizes."
      def format, do: @format
      @impl true
      def storage_type(_), do: :string
      @impl true
      def cast_input(nil, _), do: {:ok, nil}
      def cast_input(value, _) when is_binary(value) do
        case @normalize.(value) do
          {:ok, canonical} -> {:ok, canonical}
          :error -> {:error, message: @message}
        end
      end

      def cast_input(_, _), do: :error
      @impl true
      def cast_stored(value, _), do: {:ok, value}

      def json_schema(_constraints), do: struct(OpenApiSpex.Schema, type: :string, format: @format)
      def json_write_schema(_constraints), do: %{"type" => "string", "format" => @format}
      @impl true
      def dump_to_native(value, _), do: {:ok, value}
    end
  end
end

defmodule Mana.BR.Cpf do
  @moduledoc "CPF, stored as 11 digits."
  use Mana.BR.Type, format: "br-cpf",
    normalize: &Mana.BR.cast_cpf/1,
    message: "is not a valid CPF"
end

defmodule Mana.BR.Cnpj do
  @moduledoc "CNPJ, stored as 14 digits."
  use Mana.BR.Type, format: "br-cnpj",
    normalize: &Mana.BR.cast_cnpj/1,
    message: "is not a valid CNPJ"
end

defmodule Mana.BR.Cep do
  @moduledoc "CEP, stored as 8 digits."
  use Mana.BR.Type, format: "br-cep",
    normalize: &Mana.BR.cast_cep/1,
    message: "must have 8 digits"
end

defmodule Mana.BR.Phone do
  @moduledoc "Brazilian phone, stored as DDD + number digits."
  use Mana.BR.Type, format: "br-phone", normalize: &Mana.BR.phone/1, message: "is not a valid Brazilian phone"
end

defmodule Mana.BR.Plate do
  @moduledoc "Vehicle plate, legacy or Mercosul, stored uppercase without separators."
  use Mana.BR.Type, format: "br-plate",
    normalize: &Mana.BR.cast_plate/1,
    message: "is not a valid Brazilian plate"
end
