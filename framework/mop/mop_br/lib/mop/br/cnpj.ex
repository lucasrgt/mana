defmodule Mop.Br.Cnpj do
  @moduledoc """
  CNPJ validation under the alphanumeric rule of the Receita Federal (July 2026).

  A CNPJ has 14 characters: 12 base characters in `0-9` or `A-Z` and two numeric
  check digits. Each character is worth its ASCII code minus 48, so numeric CNPJs
  keep the digits they always had.
  """

  @first_weights [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]
  @second_weights [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2]

  @doc "Whether `cnpj`, already stripped of punctuation and uppercased, is valid."
  def valid?(cnpj) when is_binary(cnpj), do: valid_codes?(:binary.bin_to_list(cnpj))
  def valid?(_), do: false

  @doc "The same check over a list of character codes."
  def valid_codes?([c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12, d1, d2] = codes) do
    base = [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12]

    alphanumerics?(base) and digit?(d1) and digit?(d2) and not same?(codes) and
      [d1, d2] == check_digits(base)
  end

  def valid_codes?(_), do: false

  @doc "The two check-digit codes for 12 base character codes."
  def check_digits(base) do
    first = check_digit(weighted_sum(base, @first_weights))
    second = check_digit(weighted_sum(base ++ [first + ?0], @second_weights))
    [first + ?0, second + ?0]
  end

  @doc "The check digit for a weighted sum: 0 when the remainder by 11 is below 2."
  def check_digit(sum) do
    remainder = rem(sum, 11)
    if remainder < 2, do: 0, else: 11 - remainder
  end

  def weighted_sum([code | codes], [weight | weights]),
    do: (code - ?0) * weight + weighted_sum(codes, weights)

  def weighted_sum(_, _), do: 0

  def alphanumerics?([code | codes]), do: alphanumeric?(code) and alphanumerics?(codes)
  def alphanumerics?([]), do: true

  def alphanumeric?(code), do: digit?(code) or (is_integer(code) and code >= ?A and code <= ?Z)

  def digit?(code), do: is_integer(code) and code >= ?0 and code <= ?9

  @doc "Whether every code in a non-empty list is the same."
  def same?([code | codes]), do: all_equal?(codes, code)

  defp all_equal?([code | codes], code), do: all_equal?(codes, code)
  defp all_equal?([], _code), do: true
  defp all_equal?(_codes, _code), do: false
end
