defmodule Mana.BR do
  @moduledoc """
  Brazilian identifiers as Ash types. Each accepts formatted input, stores the
  canonical form (digits; CNPJ and plates uppercase alphanumeric) and rejects invalid
  documents with the official check digits. Kept out of `mana_core`: a country's
  scalars are not core.

  CPF and CNPJ are decided by `Mop.Br.Cpf` and `Mop.Br.Cnpj`, whose laws (the check
  digit is always a digit; generated check digits always validate) are proved for
  every input in `framework/mop/mop_br`.
  """

  alias Mop.Br

  @doc "Valid CPF (11 digits, mod-11 check digits, not all equal)."
  def cpf?(digits), do: Br.Cpf.valid?(digits)

  @doc """
  Valid CNPJ: 12 base characters in 0-9 or A-Z and 2 numeric check digits (the
  alphanumeric CNPJ the Receita Federal issues since July 2026; numeric ones stay
  valid), not all equal. Takes the canonical form: uppercase, no punctuation.
  """
  def cnpj?(cnpj), do: Br.Cnpj.valid?(cnpj)

  @doc "A legacy (ABC1234) or Mercosul (ABC1D23) plate."
  def plate?(plate),
    do: plate =~ ~r/^[A-Z]{3}[0-9]{4}$/ or plate =~ ~r/^[A-Z]{3}[0-9][A-Z][0-9]{2}$/

  def digits(value), do: String.replace(to_string(value), ~r/\D/, "")

  @doc "A CNPJ's canonical form: uppercase letters and digits, punctuation dropped."
  def cnpj(value), do: to_string(value) |> String.upcase() |> String.replace(~r/[^0-9A-Z]/, "")

  def plate(value),
    do: to_string(value) |> String.replace(~r/[^[:alnum:]]/u, "") |> String.upcase()

  @doc "A Brazilian phone without the country code: DDD + 8 or 9 digits."
  def phone(value) do
    digits = digits(value)

    digits =
      if byte_size(digits) in [12, 13] and String.starts_with?(digits, "55"),
        do: binary_part(digits, 2, byte_size(digits) - 2),
        else: digits

    if byte_size(digits) in [10, 11] and not String.starts_with?(digits, "0"),
      do: {:ok, digits},
      else: :error
  end

  @doc false
  def cast_cpf(value), do: value |> digits() |> then(&if(cpf?(&1), do: {:ok, &1}, else: :error))
  @doc false
  def cast_cnpj(value), do: value |> cnpj() |> then(&if(cnpj?(&1), do: {:ok, &1}, else: :error))
  @doc false
  def cast_cep(value),
    do: value |> digits() |> then(&if(byte_size(&1) == 8, do: {:ok, &1}, else: :error))

  @doc false
  def cast_plate(value),
    do: value |> plate() |> then(&if(plate?(&1), do: {:ok, &1}, else: :error))
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

      def json_schema(_constraints),
        do: struct(OpenApiSpex.Schema, type: :string, format: @format)

      def json_write_schema(_constraints), do: %{"type" => "string", "format" => @format}
      @impl true
      def dump_to_native(value, _), do: {:ok, value}
    end
  end
end

defmodule Mana.BR.Cpf do
  @moduledoc "CPF, stored as 11 digits."
  use Mana.BR.Type,
    format: "br-cpf",
    normalize: &Mana.BR.cast_cpf/1,
    message: "is not a valid CPF"
end

defmodule Mana.BR.Cnpj do
  @moduledoc "CNPJ, numeric or alphanumeric, stored as 14 uppercase characters."
  use Mana.BR.Type,
    format: "br-cnpj",
    normalize: &Mana.BR.cast_cnpj/1,
    message: "is not a valid CNPJ"
end

defmodule Mana.BR.Cep do
  @moduledoc "CEP, stored as 8 digits."
  use Mana.BR.Type,
    format: "br-cep",
    normalize: &Mana.BR.cast_cep/1,
    message: "must have 8 digits"
end

defmodule Mana.BR.Phone do
  @moduledoc "Brazilian phone, stored as DDD + number digits."
  use Mana.BR.Type,
    format: "br-phone",
    normalize: &Mana.BR.phone/1,
    message: "is not a valid Brazilian phone"
end

defmodule Mana.BR.Plate do
  @moduledoc "Vehicle plate, legacy or Mercosul, stored uppercase without separators."
  use Mana.BR.Type,
    format: "br-plate",
    normalize: &Mana.BR.cast_plate/1,
    message: "is not a valid Brazilian plate"
end
