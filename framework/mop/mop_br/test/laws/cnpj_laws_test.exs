defmodule Mop.Br.CnpjLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Mop.Br.Cnpj

  def valid_or_same?(codes), do: Cnpj.valid_codes?(codes) or Cnpj.same?(codes)

  laws "check digit" do
    law(check_digit_is_a_digit(sum),
      requires: is_integer(sum),
      expects: Cnpj.check_digit(sum) >= 0 and Cnpj.check_digit(sum) <= 9,
      proof: ~LEAN"""
      cases sum <;> simp [«check_digit_is_a_digit:requires/1», Erlang.erlang.«is_integer/1»] at requires
      rename_i n
      simp [«check_digit_is_a_digit:ensures/1», Elixir.Mop.Br.Cnpj.«check_digit/1»]
      have low : -11 < n.tmod 11 := by
        have := Int.lt_tmod_of_pos n (show (0 : Int) < 11 by decide); omega
      have high : n.tmod 11 < 11 := Int.tmod_lt_of_pos n (by decide)
      by_cases small : n.tmod 11 < 2 <;>
        simp [small, Erlang.erlang.«>=/2», Erlang.erlang.«=</2»] <;>
        simp [Int.compare_eq_gt, Ordering.isGE_iff_ne_lt, Int.compare_eq_lt] <;> omega
      """
    )
  end

  laws "check digits round trip" do
    law(check_digits_complete_a_valid_cnpj(c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12),
      requires: Cnpj.alphanumerics?([c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12]),
      expects:
        valid_or_same?(
          [c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12] ++
            Cnpj.check_digits([c1, c2, c3, c4, c5, c6, c7, c8, c9, c10, c11, c12])
        ),
      proof: ~LEAN"""
      open Elixir.Mop.Br.Cnpj in
      open Elixir.Mop.Br.CnpjLawsTest in
      have alnum : ∀ t, «alphanumeric?/1» t = .ok Lynx.Term.true →
          ∃ n, t = .integer n ∧ 48 ≤ n ∧ n ≤ 90 := by
        intro t h
        cases t <;> simp [«alphanumeric?/1», «digit?/1», Erlang.erlang.«is_integer/1»] at h
        rename_i n
        refine ⟨n, rfl, ?_⟩
        by_cases a : 48 ≤ n <;> by_cases b : n ≤ 57 <;> by_cases c : 65 ≤ n <;>
          by_cases d : n ≤ 90 <;> simp [a, b, c, d] at h <;> omega
      have cd : ∀ n : Int, «check_digit/1» (.integer n) =
          .ok (.integer (if n.tmod 11 < 2 then 0 else 11 - n.tmod 11)) := by
        intro n
        by_cases small : n.tmod 11 < 2 <;> simp [«check_digit/1», small]
      have digit : ∀ n : Int, «digit?/1» (.integer ((if n.tmod 11 < 2 then 0 else 11 - n.tmod 11) + 48)) =
          .ok Lynx.Term.true := by
        intro n
        have low : -11 < n.tmod 11 := by
          have := Int.lt_tmod_of_pos n (show (0 : Int) < 11 by decide); omega
        have high : n.tmod 11 < 11 := Int.tmod_lt_of_pos n (by decide)
        by_cases small : n.tmod 11 < 2 <;> simp [«digit?/1», small, Erlang.erlang.«is_integer/1»] <;> omega
      simp [«check_digits_complete_a_valid_cnpj:requires/12», «alphanumerics?/1»] at requires
      obtain ⟨r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12⟩ := requires
      obtain ⟨n1, rfl, l1, h1⟩ := alnum _ r1
      obtain ⟨n2, rfl, l2, h2⟩ := alnum _ r2
      obtain ⟨n3, rfl, l3, h3⟩ := alnum _ r3
      obtain ⟨n4, rfl, l4, h4⟩ := alnum _ r4
      obtain ⟨n5, rfl, l5, h5⟩ := alnum _ r5
      obtain ⟨n6, rfl, l6, h6⟩ := alnum _ r6
      obtain ⟨n7, rfl, l7, h7⟩ := alnum _ r7
      obtain ⟨n8, rfl, l8, h8⟩ := alnum _ r8
      obtain ⟨n9, rfl, l9, h9⟩ := alnum _ r9
      obtain ⟨n10, rfl, l10, h10⟩ := alnum _ r10
      obtain ⟨n11, rfl, l11, h11⟩ := alnum _ r11
      obtain ⟨n12, rfl, l12, h12⟩ := alnum _ r12
      simp [«check_digits_complete_a_valid_cnpj:ensures/12», «valid_or_same?/1»,
        «valid_codes?/1», «check_digits/1», «weighted_sum/2», Erlang.erlang.«++/2»,
        «alphanumerics?/1», r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12, cd, digit,
        «same?/1», «all_equal?/2», Erlang.erlang.«not/1», Erlang.erlang.«==/2»]
      by_cases e1 : n1 = n2 <;> simp [e1]
      by_cases e2 : n2 = n3 <;> simp [e2]
      by_cases e3 : n3 = n4 <;> simp [e3]
      by_cases e4 : n4 = n5 <;> simp [e4]
      by_cases e5 : n5 = n6 <;> simp [e5]
      by_cases e6 : n6 = n7 <;> simp [e6]
      by_cases e7 : n7 = n8 <;> simp [e7]
      by_cases e8 : n8 = n9 <;> simp [e8]
      by_cases e9 : n9 = n10 <;> simp [e9]
      by_cases e10 : n10 = n11 <;> simp [e10]
      by_cases e11 : n11 = n12 <;> simp [e11]
      repeat' split
      all_goals simp
      """
    )
  end
end
