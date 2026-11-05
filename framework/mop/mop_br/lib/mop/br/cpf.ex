defmodule Mop.Br.Cpf do
  @moduledoc """
  CPF validation: 11 digits, the last two being mod-11 check digits over the first nine (weights
  10 to 2) and the first ten (weights 11 to 2). A CPF whose digits are all equal passes the
  arithmetic but is not a real document, and is refused.
  """

  @first_weights [10, 9, 8, 7, 6, 5, 4, 3, 2]
  @second_weights [11, 10, 9, 8, 7, 6, 5, 4, 3, 2]

  @doc "Whether `cpf`, already stripped of punctuation, is valid."
  def valid?(cpf) when is_binary(cpf), do: valid_codes?(:binary.bin_to_list(cpf))
  def valid?(_), do: false

  @doc "The same check over a list of character codes."
  def valid_codes?([c1, c2, c3, c4, c5, c6, c7, c8, c9, d1, d2] = codes) do
    base = [c1, c2, c3, c4, c5, c6, c7, c8, c9]

    digits?(base) and digit?(d1) and digit?(d2) and not same?(codes) and
      [d1, d2] == check_digits(base)
  end

  def valid_codes?(_), do: false

  @doc "The two check-digit codes for 9 base digit codes."
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

  def digits?([code | codes]), do: digit?(code) and digits?(codes)
  def digits?([]), do: true

  def digit?(code), do: is_integer(code) and code >= ?0 and code <= ?9

  @doc "Whether every code in a non-empty list is the same."
  def same?([code | codes]), do: all_equal?(codes, code)

  defp all_equal?([code | codes], code), do: all_equal?(codes, code)
  defp all_equal?([], _code), do: true
  defp all_equal?(_codes, _code), do: false
end
