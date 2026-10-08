defmodule {{Module}}.{{Record}} do
  use Ash.Resource,
    domain: {{Module}}.{{Collection}},
    data_layer: AshPostgres.DataLayer,
    extensions: [AshJsonApi.Resource],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table("{{name}}")
    repo({{Module}}.Repo)
    custom_indexes do
      index([:owner_id, :id])
    end
  end

  json_api do
    type("{{type}}")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :string, allow_nil?: false)
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:{{state}}, :boolean, public?: true, default: false, allow_nil?: false)
  end

  actions do
    defaults([:read])
    read :list do
      prepare(build(sort: [:id], limit: 100))
    end
    update :{{action}} do
      accept([])
      change(set_attribute(:{{state}}, true))
    end
  end

  policies do
    policy action_type([:read, :update]) do
      forbid_unless(actor_present())
      authorize_if(expr(owner_id == ^actor(:id)))
    end
  end
end

defmodule {{Module}}.{{Collection}} do
  use Ash.Domain, extensions: [AshJsonApi.Domain, Moments.Extension]
  resources do
    resource({{Module}}.{{Record}})
  end
  json_api do
    routes do
      base_route "/{{name}}", {{Module}}.{{Record}} do
        index(:list, name: "list{{Collection}}")
        patch(:{{action}}, route: "/:id/{{action}}", name: "{{actionCamel}}{{Record}}")
      end
    end
  end

  moments do
    base(:{{baseAtom}})
    route("/{{name}}")
    client_roots(["lib/features/{{name}}.dart"])
    watch(["lib/generated/mana_routes.dart"])
    field(:filter, "all", values: ["all", "changed"])
    field(:scrollOffset, 0, min: 0, max: 10_000_000)
    field(:ids, "none", max_length: 3699, restore: false)
    field(:changedIds, "none", max_length: 3699, restore: false)

    moment :{{name}}_inbox do
      backend(:{{name}}_inbox)
      description("Observe persisted {{name}} without repeating writes.")
      check(:same_records, kind: :backend_equals, field: :storage, equals: "ash-postgres", match: :ids)
      check(:same_state, kind: :backend_equals, field: :storage, equals: "ash-postgres", match: :changedIds)
    end

    moment :{{name}}_{{action}} do
      backend(:{{name}}_journey)
      description("{{Action}} through Flutter and confirm persisted state.")
      step(:{{action}}, tap: "{{action}}-{{fixtureId}}", until: [:changed, :ui_agrees])
      check(:changed, kind: :backend_equals, field: :changed, equals: true, match: :ids)
      check(:ui_agrees, kind: :backend_equals, field: :storage, equals: "ash-postgres", match: :changedIds)
      check(:filter_preserved, kind: :restored, field: :filter, equals: "all")
    end
  end
end
