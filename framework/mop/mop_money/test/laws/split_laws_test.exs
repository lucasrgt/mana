defmodule Mop.Money.SplitLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Mop.Money.Split

  def integers?([value | values]), do: is_integer(value) and integers?(values)
  def integers?([]), do: true
  def integers?(_), do: false

  laws "rescale closes" do
    law(rescale_closes_with_the_total(values, total),
      requires:
        integers?(values) and values != [] and is_integer(total) and total > 0 and
          Split.sum(values) > 0,
      expects: Split.sum(Split.rescale(values, total)) == total,
      proof: ~LEAN"""
      open Elixir.Mop.Money.Split in
      open Elixir.Mop.Money.SplitLawsTest in
      have fdiv : ∀ x y : Int, y ≠ 0 →
          ∃ q, Elixir.Integer.«floor_div/2» (.integer x) (.integer y) = .ok (.integer q) := by
        intro x y hy
        simp only [Elixir.Integer.«floor_div/2», Erlang.erlang.«</2_integers»]
        by_cases a : x < 0 <;> by_cases b : y < 0 <;> by_cases c : x.tmod y = 0 <;>
          simp [a, b, c, hy, Erlang.erlang.«xor/2», Erlang.erlang.«rem/2», Erlang.erlang.«div/2»]
      have sumInt : ∀ l, «integers?/1» l = .ok Lynx.Term.true →
          ∃ s, «sum/1» l = .ok (.integer s) := by
        intro l
        induction l
        case cons h t hh iht =>
          clear hh
          intro hl
          cases h <;> simp [«integers?/1», Erlang.erlang.«is_integer/1»] at hl
          rename_i n
          obtain ⟨s, hs⟩ := iht hl
          exact ⟨n + s, by simp [«sum/1», hs]⟩
        case nil => intro _; exact ⟨0, by simp [«sum/1»]⟩
        all_goals (intro hl; simp [«integers?/1»] at hl)
      have scaleInt : ∀ l, «integers?/1» l = .ok Lynx.Term.true → ∀ t src : Int, src ≠ 0 →
          ∃ l', «scale/3» l (.integer t) (.integer src) = .ok l' ∧
            «integers?/1» l' = .ok Lynx.Term.true ∧
            (l ≠ .nil → ∃ q rest, l' = .cons (.integer q) rest) := by
        intro l
        induction l
        case cons h tl hh iht =>
          clear hh
          intro hl t src hsrc
          cases h <;> simp [«integers?/1», Erlang.erlang.«is_integer/1»] at hl
          rename_i n
          obtain ⟨l', hs, hi, _⟩ := iht hl t src hsrc
          obtain ⟨q, hq⟩ := fdiv (n * t) src hsrc
          exact ⟨.cons (.integer q) l', by simp [«scale/3», hq, hs],
            by simp [«integers?/1», Erlang.erlang.«is_integer/1», hi], fun _ => ⟨q, l', rfl⟩⟩
        case nil => intro _ t src _; exact ⟨.nil, by simp [«scale/3»], by simp [«integers?/1»], by simp⟩
        all_goals (intro hl; simp [«integers?/1»] at hl)
      cases total <;> simp [«rescale_closes_with_the_total:requires/2», Erlang.erlang.«is_integer/1»] at requires
      rename_i T
      obtain ⟨⟨⟨hint, hne⟩, hT⟩, hsum⟩ := requires
      obtain ⟨S, hS⟩ := sumInt values hint
      simp [hS, Erlang.erlang.«>/2»] at hsum
      have hS0 : S ≠ 0 := by
        intro h; simp [h] at hsum
      obtain ⟨l', hsc, hi', hcons⟩ := scaleInt values hint T S hS0
      cases values
      case cons v vs =>
        obtain ⟨q, rest, rfl⟩ := hcons (by simp)
        have hirest : «integers?/1» rest = .ok Lynx.Term.true := by
          simpa [«integers?/1», Erlang.erlang.«is_integer/1»] using hi'
        obtain ⟨R, hR⟩ := sumInt rest hirest
        have hT' : ¬ T ≤ 0 := by omega
        have hS' : 0 < S := by simpa [Int.compare_eq_gt] using hsum
        have c1 : (compare T 0).isLE = false := by
          simp [Int.compare_eq_gt, hT]
        have c2 : (compare S 0).isLE = false := by
          simp [Int.compare_eq_gt, hS']
        simp only [«rescale_closes_with_the_total:ensures/2», «rescale/2»]
        simp [Erlang.erlang.«=</2», c1]
        rw [hS]
        simp [c2, hsc, «close/2»]
        simp [«sum/1», hR, Erlang.erlang.«==/2»]
        omega
      all_goals simp [«integers?/1», Erlang.erlang.«/=/2»] at hint hne
      """
    )
  end
end
