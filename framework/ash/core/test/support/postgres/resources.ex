defmodule PostgresTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(PostgresTest.Order)
    resource(PostgresTest.HistoryEntry)
    resource(PostgresTest.Traveler)
    resource(PostgresTest.Booking)
    resource(PostgresTest.Review)
    resource(PostgresTest.Card)
  end
end

defmodule PostgresTest.Probe do
  @moduledoc false
  # What the harness's broadcaster, sender, error reporter and telemetry saw, sent to the
  # test that asked (`Application.put_env(:mana_core, :postgres_test_pid, self())`).

  def broadcast(topic, event, _payload),
    do: tell({:broadcast, topic, event, Ash.DataLayer.in_transaction?(PostgresTest.Order)})

  def deliver(notice) do
    tell({:notice, notice.template, Ash.DataLayer.in_transaction?(PostgresTest.Order)})
    :ok
  end

  def entry(_event, _measurements, meta, _config),
    do: tell({:entry, meta.action, Ash.DataLayer.in_transaction?(PostgresTest.Order)})

  def report(failure, error) do
    tell({:reported, failure, Exception.message(error)})
    "report-1"
  end

  defp tell(message) do
    if pid = Application.get_env(:mana_core, :postgres_test_pid), do: send(pid, message)
    :ok
  end
end

defmodule PostgresTest.Order do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Entity, Mana.Verbs, Mana.History, Mana.Notifications]

  postgres do
    table("orders")
    repo(PostgresTest.Repo)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:buyer_id, :uuid, public?: true)
    attribute(:title, :string, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :paid, :cancelled, :expired]],
      default: :open,
      allow_nil?: false,
      public?: true
    )
  end

  actions do
    defaults([:read, :destroy, create: [:buyer_id, :title]])

    update :pay do
      change(set_attribute(:status, :paid))
      # A payment that takes a while to write, so a racing deadline checks
      # `when` before it commits.
      change(fn changeset, _context ->
        Ash.Changeset.after_action(changeset, fn _changeset, record ->
          Process.sleep(Application.get_env(:mana_core, :postgres_pay_ms, 0))
          {:ok, record}
        end)
      end)
    end

    update(:cancel, change: set_attribute(:status, :cancelled))
    update(:expire, change: set_attribute(:status, :expired))
    update(:rename, accept: [:title])
  end

  verbs do
    verb(:pay, when: expr(status == :open))
    verb(:cancel, when: expr(status == :open))
  end

  entity do
    broadcast(PostgresTest.Probe)
    audience([:buyer_id])
    deadline(:unpaid, action: :expire, when: expr(status == :open), after: {30, :minute})
  end

  history do
    log(PostgresTest.HistoryEntry)
  end

  notifications do
    sender(PostgresTest.Probe)
    notify(:pay, to: :buyer_id, template: "order.paid")
  end
end

defmodule PostgresTest.HistoryEntry do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.History.Log]

  postgres do
    table("history_entries")
    repo(PostgresTest.Repo)
  end

  history_log do
    subjects([PostgresTest.Order, PostgresTest.Booking, PostgresTest.Review, PostgresTest.Card])
  end
end

defmodule PostgresTest.Traveler do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Resource]

  postgres do
    table("travelers")
    repo(PostgresTest.Repo)
  end

  privacy do
    subject(:id)
    export([:name, :email])
    erase(:delete)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:name, :string, public?: true)
    attribute(:email, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:id, :name, :email]])
  end
end

defmodule PostgresTest.Booking do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Resource, Mana.History]

  postgres do
    table("bookings")
    repo(PostgresTest.Repo)
  end

  privacy do
    subject(:traveler_id)
    export([:guest_name, :phone, :nights])
    personal([:guest_name, :phone])
    erase(:keep)
    reason("the host keeps its bookings")
  end

  history do
    log(PostgresTest.HistoryEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:traveler_id, :uuid, public?: true)
    attribute(:guest_name, :string, public?: true)
    attribute(:phone, :string, public?: true)
    attribute(:nights, :integer, public?: true)
  end

  actions do
    defaults([:read, create: [:traveler_id, :guest_name, :phone, :nights]])
    update(:amend, accept: [:guest_name, :phone, :nights])
  end
end

defmodule PostgresTest.Review do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Resource, Mana.History]

  postgres do
    table("reviews")
    repo(PostgresTest.Repo)
  end

  privacy do
    subject(:author_id)
    export([:text])
    erase(:detach)
    reason("the place keeps its reviews")
  end

  history do
    log(PostgresTest.HistoryEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:author_id, :uuid, public?: true)
    attribute(:text, :string, public?: true)
    attribute(:public, :boolean, default: true, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, create: [:author_id, :text]])

    update :detach do
      change(set_attribute(:author_id, nil))
      change(set_attribute(:public, false))
    end
  end
end

defmodule PostgresTest.Card do
  @moduledoc false
  use Ash.Resource,
    domain: PostgresTest.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [Mana.Verbs, Mana.History]

  postgres do
    table("cards")
    repo(PostgresTest.Repo)
  end

  history do
    log(PostgresTest.HistoryEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:title, :string, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:draft, :open, :closed]],
      default: :draft,
      allow_nil?: false,
      public?: true
    )

    attribute(:archived, :boolean, default: false, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
    create(:draft, accept: [:title])
    update(:publish, change: set_attribute(:status, :open))
    update(:close, change: set_attribute(:status, :closed))
    update(:reopen, change: set_attribute(:status, :open))
    update(:archive, change: set_attribute(:archived, true))
  end

  verbs do
    verb(:draft, collection: true)
    verb(:publish, when: expr(status == :draft))
    verb(:close, when: expr(status == :open), inverse: :reopen)
    verb(:reopen, when: expr(status == :closed), inverse: :close)
    verb(:archive, when: expr(status == :closed), idempotent: true)
  end
end
