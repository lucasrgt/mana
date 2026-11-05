# MIX_ENV=test mix run demo/bug_rem_below_one.exs
#
# A subtle, common CNPJ bug: treating only remainder 0 as "check digit 0".
# With remainder 1 the buggy code returns 11 - 1 = 10, which is not a digit.
# The same law and the same proof that pass for Mop.Br.Cnpj must fail here.
ExUnit.start()

defmodule BuggyCnpjLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  def check_digit(sum) do
    remainder = rem(sum, 11)
    if remainder < 1, do: 0, else: 11 - remainder
  end

  test "counterexample: a sum with remainder 1 yields 10, which is not a digit" do
    assert check_digit(1) == 10
    assert check_digit(12) == 10
  end

  laws "buggy check digit" do
    law check_digit_is_a_digit(sum),
      requires: is_integer(sum),
      expects: check_digit(sum) >= 0 and check_digit(sum) <= 9,
      proof: ~LEAN"""
      cases sum <;> simp [«check_digit_is_a_digit:requires/1», Erlang.erlang.«is_integer/1»] at requires
      rename_i n
      simp [«check_digit_is_a_digit:ensures/1», «check_digit/1»]
      have low : -11 < n.tmod 11 := by
        have := Int.lt_tmod_of_pos n (show (0 : Int) < 11 by decide); omega
      have high : n.tmod 11 < 11 := Int.tmod_lt_of_pos n (by decide)
      by_cases small : n.tmod 11 < 1 <;>
        simp [small, Erlang.erlang.«>=/2», Erlang.erlang.«=</2»] <;>
        simp [Int.compare_eq_gt, Ordering.isGE_iff_ne_lt, Int.compare_eq_lt] <;> omega
      """
  end
end
