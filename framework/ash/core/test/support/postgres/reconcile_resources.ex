defmodule PostgresTest.ReconcileDomain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.Ledger)
  end
end

defmodule PostgresTest.Ledger do
  @moduledoc false
  # `holds:` expressions SQL would read with the wrong precedence once
  # wrapped by the rule: a negation and a disjunction.
  use Ash.Resource,
    domain: PostgresTest.ReconcileDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Reconcile]

  postgres do
    table("ledgers")
    repo(PostgresTest.Repo)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:status, :atom,
      constraints: [one_of: [:paid, :waived]],
      allow_nil?: false,
      public?: true
    )

    attribute(:charge_id, :uuid, public?: true)
    attribute(:refunded, :boolean, public?: true)
  end

  actions do
    defaults([:read, create: [:status, :charge_id, :refunded]])
  end

  reconcile do
    desired(:not_refunded, "a ledger is not refunded",
      scope: expr(true),
      holds: expr(not refunded)
    )

    desired(:charged_or_waived, "a ledger is charged, or waived",
      scope: expr(true),
      holds: expr(not is_nil(charge_id) or status == :waived)
    )
  end
end
