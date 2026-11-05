defmodule Mop.Access.LawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Mop.Access

  def nil_or_pair?(nil), do: true
  def nil_or_pair?({_, _}), do: true
  def nil_or_pair?(_), do: false

  def applicable(policies, resource) do
    case Access.policy(policies, resource) do
      {applicable, _defaults} -> applicable
      _ -> []
    end
  end

  def defaults(policies, resource) do
    case Access.policy(policies, resource) do
      {_applicable, defaults} -> defaults
      _ -> []
    end
  end

  @policy_shape ~LEAN"""
  open Elixir.Mop.Access in
  have shape : ∀ ps r, «policy/2» ps r = .ok (.atom "nil") ∨
      ∃ a d, «policy/2» ps r = .ok (.tuple #[a, d]) := by
    intro ps
    induction ps
    case cons h t hh iht =>
      clear hh
      intro r
      rw [«policy/2»]
      dsimp only
      split
      · simp only [Erlang.erlang.«=:=/2»]
        split <;> simp [*]
      · exact iht _
    all_goals (intro r; rw [«policy/2»] <;> simp <;> intros <;> simp_all)
  """

  @member_bool ~LEAN"""
  open Elixir.Mop.Access in
  have memberBool : ∀ l v, «member?/2» l v = .ok Lynx.Term.true ∨ «member?/2» l v = .ok Lynx.Term.false := by
    intro l
    induction l
    case cons h t hh iht =>
      clear hh
      intro v
      rw [«member?/2»]
      simp [Erlang.erlang.«=:=/2»]
      by_cases e : v.exactCompare h = .eq <;> simp [e]
      exact iht v
    all_goals (intro v; rw [«member?/2»] <;> simp <;> intros <;> simp_all)
  """

  @lookups ~LEAN"""
  open Elixir.Mop.Access in
  have overrideOk : ∀ os r a, ∃ e, «override/3» os r a = .ok e := by
    intro os
    induction os
    case cons h t hh iht =>
      clear hh
      intro r a
      rw [«override/3»]
      dsimp only
      split
      · simp only [Erlang.erlang.«=:=/2»]
        split <;> split <;> simp [Erlang.erlang.«and/2»] <;> (try split) <;>
          first | exact iht _ _ | simp_all
      · exact iht _ _
    all_goals (intro r a; rw [«override/3»] <;> simp <;> intros <;> simp_all)
  have defaultsOk : ∀ ds role, ∃ x, «defaults_for/2» ds role = .ok x := by
    intro ds
    induction ds
    case cons h t hh iht =>
      clear hh
      intro role
      rw [«defaults_for/2»]
      dsimp only
      split
      · simp only [Erlang.erlang.«=:=/2»]
        split <;> simp [*]
      · exact iht _
    all_goals (intro role; rw [«defaults_for/2»] <;> simp <;> intros <;> simp_all)
  """

  laws "access" do
    law(member_is_boolean(values, value),
      expects: is_boolean(Access.member?(values, value)),
      proof:
        Mop.Proof.join([
          @member_bool,
          ~LEAN"""
          rcases memberBool values value with h | h <;>
            simp [«member_is_boolean:ensures/2», h, Erlang.erlang.«is_boolean/1»]
          """
        ])
    )

    law(policy_is_nil_or_pair(policies, resource),
      expects: nil_or_pair?(Access.policy(policies, resource)),
      proof:
        Mop.Proof.join([
          @policy_shape,
          ~LEAN"""
          rcases shape policies resource with h | ⟨a, d, h⟩ <;>
            simp [«policy_is_nil_or_pair:ensures/2», h, «nil_or_pair?/1»]
          """
        ])
    )

    law(superuser_may_do_everything(role, overrides, policies, resource, action),
      expects: Access.allowed?(true, role, overrides, policies, resource, action) === true,
      proof: ~LEAN"""
      simp [«superuser_may_do_everything:ensures/5», Elixir.Mop.Access.«allowed?/6»,
        Erlang.erlang.«=:=/2»]
      """
    )

    law(ungoverned_resource_is_closed(role, overrides, policies, resource, action),
      requires: Access.policy(policies, resource) === nil,
      expects: Access.allowed?(false, role, overrides, policies, resource, action) === false,
      proof:
        Mop.Proof.join([
          @policy_shape,
          ~LEAN"""
          open Elixir.Mop.Access in
          rcases shape policies resource with h | ⟨a, d, h⟩
          · simp [«ungoverned_resource_is_closed:ensures/5», «allowed?/6», h, Erlang.erlang.«=:=/2»]
          · simp [«ungoverned_resource_is_closed:requires/5», h, Erlang.erlang.«=:=/2»] at requires
          """
        ])
    )

    law(deny_always_wins(role, overrides, policies, resource, action),
      requires: Access.override(overrides, resource, action) === :deny,
      expects: Access.allowed?(false, role, overrides, policies, resource, action) === false,
      proof:
        Mop.Proof.join([
          @member_bool,
          @policy_shape,
          @lookups,
          ~LEAN"""
          obtain ⟨e, he⟩ := overrideOk overrides resource action
          simp [«deny_always_wins:requires/5», he, Erlang.erlang.«=:=/2»] at requires
          subst requires
          rcases shape policies resource with h | ⟨a, d, h⟩
          · simp [«deny_always_wins:ensures/5», «allowed?/6», h, Erlang.erlang.«=:=/2»]
          · rcases memberBool a action with m | m <;>
              simp [«deny_always_wins:ensures/5», «allowed?/6», «cell?/5», h, he, m, Erlang.erlang.«=:=/2»]
          """
        ])
    )

    law(inapplicable_action_is_never_allowed(role, overrides, policies, resource, action),
      requires: not Access.member?(applicable(policies, resource), action),
      expects: Access.allowed?(false, role, overrides, policies, resource, action) === false,
      proof:
        Mop.Proof.join([
          @member_bool,
          @policy_shape,
          ~LEAN"""
          rcases shape policies resource with h | ⟨a, d, h⟩
          · simp [«inapplicable_action_is_never_allowed:ensures/5», «allowed?/6», h, Erlang.erlang.«=:=/2»]
          · rcases memberBool a action with m | m
            · simp [«inapplicable_action_is_never_allowed:requires/5», «applicable/2», h, m,
                Erlang.erlang.«not/1»] at requires
            · simp [«inapplicable_action_is_never_allowed:ensures/5», «allowed?/6», h, m,
                Erlang.erlang.«=:=/2»]
          """
        ])
    )

    law(allow_grants_an_applicable_action(role, overrides, policies, resource, action),
      requires:
        Access.member?(applicable(policies, resource), action) and
          Access.override(overrides, resource, action) === :allow,
      expects: Access.allowed?(false, role, overrides, policies, resource, action) === true,
      proof:
        Mop.Proof.join([
          @member_bool,
          @policy_shape,
          @lookups,
          ~LEAN"""
          obtain ⟨e, he⟩ := overrideOk overrides resource action
          rcases shape policies resource with h | ⟨a, d, h⟩
          · simp [«allow_grants_an_applicable_action:requires/5», «applicable/2», h, «member?/2»] at requires
          · rcases memberBool a action with m | m
            · simp [«allow_grants_an_applicable_action:requires/5», «applicable/2», h, m, he,
                Erlang.erlang.«=:=/2»] at requires
              subst requires
              simp [«allow_grants_an_applicable_action:ensures/5», «allowed?/6», «cell?/5», h, he, m,
                Erlang.erlang.«=:=/2»]
            · simp [«allow_grants_an_applicable_action:requires/5», «applicable/2», h, m] at requires
          """
        ])
    )

    law(role_default_decides_without_override(role, overrides, policies, resource, action),
      requires: Access.override(overrides, resource, action) === nil,
      expects:
        Access.allowed?(false, role, overrides, policies, resource, action) ===
          (Access.member?(applicable(policies, resource), action) and
             Access.member?(Access.defaults_for(defaults(policies, resource), role), action)),
      proof:
        Mop.Proof.join([
          @member_bool,
          @policy_shape,
          @lookups,
          ~LEAN"""
          obtain ⟨e, he⟩ := overrideOk overrides resource action
          simp [«role_default_decides_without_override:requires/5», he, Erlang.erlang.«=:=/2»] at requires
          subst requires
          rcases shape policies resource with h | ⟨a, d, h⟩
          · simp [«role_default_decides_without_override:ensures/5», «allowed?/6», «applicable/2»,
              «defaults/2», h, «member?/2», Erlang.erlang.«=:=/2»]
          · obtain ⟨x, hx⟩ := defaultsOk d role
            rcases memberBool a action with m | m <;> rcases memberBool x action with n | n <;>
              simp [«role_default_decides_without_override:ensures/5», «allowed?/6», «cell?/5»,
                «applicable/2», «defaults/2», h, he, hx, m, n, Erlang.erlang.«=:=/2»]
          """
        ])
    )

    law(offered_matches_allowed(superuser?, role, overrides, policies, resource, action),
      requires: is_boolean(superuser?) and is_atom(action),
      expects:
        Access.member?(Access.offered(superuser?, role, overrides, policies, resource), action) ===
          (Access.member?(applicable(policies, resource), action) and
             Access.allowed?(superuser?, role, overrides, policies, resource, action)),
      proof:
        Mop.Proof.join([
          @member_bool,
          @policy_shape,
          @lookups,
          ~LEAN"""
          have cellBool : ∀ d a, «cell?/5» role overrides d resource a = .ok Lynx.Term.true ∨
              «cell?/5» role overrides d resource a = .ok Lynx.Term.false := by
            intro d a
            obtain ⟨e, he⟩ := overrideOk overrides resource a
            obtain ⟨x, hx⟩ := defaultsOk d role
            simp only [«cell?/5», he, hx, bind, Except.bind]
            rcases memberBool x a with m | m <;> split <;> simp [m]
          simp [«offered_matches_allowed:requires/6», Erlang.erlang.«is_boolean/1»,
            Erlang.erlang.«is_atom/1»] at requires
          obtain ⟨hs, ha⟩ := requires
          have hs' : superuser? = .atom "true" ∨ superuser? = .atom "false" := by
            split at hs <;> simp_all
          cases action <;> simp at ha
          rename_i n
          have allowedBool : ∀ a, «allowed?/6» superuser? role overrides policies resource a = .ok Lynx.Term.true ∨
              «allowed?/6» superuser? role overrides policies resource a = .ok Lynx.Term.false := by
            intro a
            rcases hs' with rfl | rfl
            · simp [«allowed?/6»]
            · rcases shape policies resource with h | ⟨al, d, h⟩
              · simp [«allowed?/6», h]
              · rcases memberBool al a with m | m <;> rcases cellBool d a with c | c <;>
                  simp [«allowed?/6», h, m, c]
          have toAtom : ∀ x, (Lynx.Term.atom n).exactCompare x = .eq → x = .atom n := by
            intro x e
            have swap := Std.OrientedCmp.eq_swap (cmp := Lynx.Term.exactCompare) (a := x) (b := .atom n)
            rw [e] at swap
            exact (Lynx.Term.exactCompare_eq_atom x n).mp swap
          have memCons : ∀ x rest, «member?/2» (.cons x rest) (.atom n) =
              if (Lynx.Term.atom n).exactCompare x = .eq then .ok Lynx.Term.true
              else «member?/2» rest (.atom n) := by
            intro x rest
            rw [«member?/2»]
            by_cases e : (Lynx.Term.atom n).exactCompare x = .eq <;> simp [e, Erlang.erlang.«=:=/2»]
          have keep : ∀ l, ∃ k, «keep_allowed/6» l superuser? role overrides policies resource = .ok k ∧
              («member?/2» k (.atom n) = .ok Lynx.Term.true ↔
                («member?/2» l (.atom n) = .ok Lynx.Term.true ∧
                  «allowed?/6» superuser? role overrides policies resource (.atom n) = .ok Lynx.Term.true)) := by
            intro l
            induction l
            case cons x t hh iht =>
              clear hh
              obtain ⟨k, hk, hiff⟩ := iht
              rcases allowedBool x with al | al
              · refine ⟨.cons x k, by simp [«keep_allowed/6», hk, al], ?_⟩
                rw [memCons, memCons]
                by_cases e : (Lynx.Term.atom n).exactCompare x = .eq
                · have hx := toAtom x e
                  subst hx
                  simp [al]
                · simpa [e] using hiff
              · refine ⟨k, by simp [«keep_allowed/6», hk, al], ?_⟩
                rw [memCons]
                by_cases e : (Lynx.Term.atom n).exactCompare x = .eq
                · have hx := toAtom x e
                  subst hx
                  simp only [e, ite_true]
                  constructor
                  · intro hm
                    have := (hiff.mp hm).2
                    rw [al] at this
                    simp at this
                  · intro hm
                    rw [al] at hm
                    simp at hm
                · simpa [e] using hiff
            all_goals
              refine ⟨.nil, by simp [«keep_allowed/6»], ?_⟩
              constructor
              · intro hm
                rw [«member?/2».eq_def] at hm
                simp at hm
              · intro hm
                obtain ⟨h1, _⟩ := hm
                rw [«member?/2».eq_def] at h1
                simp at h1
          rcases shape policies resource with h | ⟨al, d, h⟩
          · simp [«offered_matches_allowed:ensures/6», «offered/5», «applicable/2», h, «member?/2»,
              Erlang.erlang.«=:=/2»]
          · obtain ⟨k, hk, hiff⟩ := keep al
            rcases memberBool k (.atom n) with mk | mk <;> rcases memberBool al (.atom n) with ma | ma <;>
              rcases allowedBool (.atom n) with aa | aa <;>
              simp_all [«offered_matches_allowed:ensures/6», «offered/5», «applicable/2», Erlang.erlang.«=:=/2»]
          """
        ])
    )
  end
end
