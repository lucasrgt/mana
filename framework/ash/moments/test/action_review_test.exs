defmodule Moments.ActionReviewTest do
  use ExUnit.Case, async: true

  defmodule GlobalChange do
    use Ash.Resource.Change
    def change(_, _, _), do: raise("planner must never run global changes")
  end

  defmodule Resource do
    use Ash.Resource,
      domain: Moments.ActionReviewTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      authorizers: [Ash.Policy.Authorizer]

    attributes do
      uuid_primary_key(:id)
      attribute(:value, :string, public?: true)
    end

    actions do
      defaults([:read])

      create :create do
        accept([:value])
        change(set_attribute(:value, "private-action-option"))
      end

      action :opaque do
        run(fn _, _ -> raise "planner must never execute this" end)
      end
    end

    changes do
      change({GlobalChange, secret: "private-global-option"}, on: [:create])
    end

    policies do
      policy always() do
        authorize_if(always())
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, extensions: [Moments.Extension], validate_config_inclusion?: false

    resources do
      resource(Moments.ActionReviewTest.Resource)
    end

    moments do
      route("/fixture")

      moment :a_candidate do
        description("Not proof of executing a specific action")
      end

      moment :another_candidate do
        description("Also only a domain candidate")
      end
    end
  end

  defmodule NoPolicy do
    use Ash.Resource, domain: nil, validate_domain_inclusion?: false

    actions do
      action :perform do
        run(fn _, _ -> raise "must not execute" end)
      end
    end
  end

  test "read plans do not invent mutations, external payments, jobs or approvals" do
    plan = Moments.ActionReview.build(Resource, "read")
    assert plan.status == "planned"
    assert plan.executed == false
    assert plan.verification == "not-performed"
    assert Enum.map(plan.reviews, & &1.id) == ["authorization", "persistence"]
    assert Enum.all?(plan.reviews, &(&1.level == "reviewed" and &1.status == "pending"))
    refute Enum.any?(plan.properties, &(&1.level == "guaranteed"))
    assert Enum.map(plan.properties, & &1.property) == ["authorization-path"]
  end

  test "global and action changes select custom execution without exposing options" do
    plan = Moments.ActionReview.build(Resource, "create")

    assert Enum.map(plan.reviews, & &1.id) == [
             "authorization",
             "persistence",
             "transactions",
             "custom-execution"
           ]

    assert %{kind: "change", implementation: "Ash.Resource.Change.SetAttribute"} in plan.facts.hooks

    assert %{kind: "change", implementation: inspect(GlobalChange)} in plan.facts.hooks
    encoded = Jason.encode!(plan)
    refute String.contains?(encoded, "private-action-option")
    refute String.contains?(encoded, "private-global-option")
    assert length(plan.unknowns) >= 3
  end

  test "opaque implementations are inspected, never called, and are not assumed safe" do
    plan = Moments.ActionReview.build(NoPolicy, "perform")
    assert plan.properties == []
    assert plan.moments == []
    assert Enum.map(plan.reviews, & &1.id) == ["authorization", "custom-execution"]
    assert Enum.any?(plan.facts.hooks, &(&1.kind == "run"))
    refute String.contains?(Jason.encode!(plan), "must not execute")
  end

  test "domain candidates explicitly lack action coverage evidence" do
    plan = Moments.ActionReview.build(Resource, "create")
    assert Enum.map(plan.moments, & &1.name) == ["a-candidate", "another-candidate"]

    assert Enum.all?(
             plan.moments,
             &(&1.coverage == "unverified" and &1.relation == "same-primary-domain")
           )

    assert plan.target.action == "create"
  end

  test "unknown resources and actions fail rather than emit an empty successful review" do
    assert_raise ArgumentError, fn -> Moments.ActionReview.build(String, "read") end
    assert_raise ArgumentError, fn -> Moments.ActionReview.build(Resource, "missing_action") end
  end
end
