defmodule Mop.AccessTest do
  use ExUnit.Case, async: true

  alias Mop.Access

  @policies [
    {:jobs, [:view, :create, :edit, :delete],
     [{:manager, [:view, :create, :edit, :delete]}, {:member, [:view, :edit]}]},
    {:audit_log, [:view], [{:manager, [:view]}]}
  ]

  test "a member without overrides gets the role default" do
    assert Access.offered(false, :member, [], @policies, :jobs) == [:view, :edit]
    refute Access.allowed?(false, :member, [], @policies, :jobs, :delete)
  end

  test "overrides grant and revoke single cells" do
    overrides = [{:jobs, :delete, :allow}, {:jobs, :edit, :deny}]
    assert Access.offered(false, :member, overrides, @policies, :jobs) == [:view, :delete]
  end

  test "a read-only resource never allows writes, and an unknown resource is closed" do
    refute Access.allowed?(
             false,
             :manager,
             [{:audit_log, :delete, :allow}],
             @policies,
             :audit_log,
             :delete
           )

    refute Access.allowed?(false, :manager, [], @policies, :reports, :view)
    assert Access.allowed?(true, :owner, [], @policies, :reports, :view)
  end

  test "reconcile stores only the cells that differ from the role default" do
    rows = Access.reconcile(:member, @policies, :jobs, [:view, :delete])
    assert rows == [{:jobs, :edit, :deny}, {:jobs, :delete, :allow}]
    assert Access.offered(false, :member, rows, @policies, :jobs) == [:view, :delete]
  end
end
