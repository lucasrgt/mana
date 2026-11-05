# MIX_ENV=test mix run demo/bug_override_before_applicable.exs
#
# PubPauta's resolver lets an override decide before checking that the resource exposes the
# action. The same law and proof that pass for Mop.Access must fail here.
ExUnit.start()

defmodule BuggyAccessLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  # PubPauta's cell rule (UserPermissions.Effective): an override decides before the
  # resource's applicable actions are consulted.
  def allowed?(true, _role, _overrides, _policies, _resource, _action), do: true

  def allowed?(false, role, overrides, policies, resource, action) do
    case Mop.Access.policy(policies, resource) do
      {applicable, defaults} ->
        case Mop.Access.override(overrides, resource, action) do
          :allow ->
            true

          nil ->
            Mop.Access.member?(applicable, action) and
              Mop.Access.member?(Mop.Access.defaults_for(defaults, role), action)

          _deny ->
            false
        end

      nil ->
        false
    end
  end

  test "counterexample: a stale Allow on an action the resource no longer exposes" do
    policies = [{:jobs, [:view], [{:member, [:view]}]}]
    overrides = [{:jobs, :delete, :allow}]

    assert allowed?(false, :member, overrides, policies, :jobs, :delete)
    refute Mop.Access.allowed?(false, :member, overrides, policies, :jobs, :delete)
    assert Mop.Access.offered(false, :member, overrides, policies, :jobs) == [:view]
  end

  def nil_or_pair?(nil), do: true
  def nil_or_pair?({_, _}), do: true
  def nil_or_pair?(_), do: false

  def applicable(policies, resource) do
    case Mop.Access.policy(policies, resource) do
      {applicable, _defaults} -> applicable
      _ -> []
    end
  end

  def defaults(policies, resource) do
    case Mop.Access.policy(policies, resource) do
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

  laws "buggy access" do
    law inapplicable_action_is_never_allowed(role, overrides, policies, resource, action),
      requires: not Mop.Access.member?(applicable(policies, resource), action),
      expects: allowed?(false, role, overrides, policies, resource, action) === false,
      proof: Mop.Proof.join([@member_bool, @policy_shape, ~LEAN"""
      rcases shape policies resource with h | ⟨a, d, h⟩
      · simp [«inapplicable_action_is_never_allowed:ensures/5», Elixir.BuggyAccessLawsTest.«allowed?/6», h, Erlang.erlang.«=:=/2»]
      · rcases memberBool a action with m | m
        · simp [«inapplicable_action_is_never_allowed:requires/5», «applicable/2», h, m,
            Erlang.erlang.«not/1»] at requires
        · simp [«inapplicable_action_is_never_allowed:ensures/5», Elixir.BuggyAccessLawsTest.«allowed?/6», h, m,
            Erlang.erlang.«=:=/2»]
      """])

  end
end
