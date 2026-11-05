# The resources and domain mana_core's tests run against, shared with the contracts
# package's tests (its test environment compiles this file too).

defmodule ManaCoreTest.Limiter do
  @moduledoc false
  def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def hit(key, window, limit) do
    count =
      Agent.get_and_update(__MODULE__, fn counts ->
        Map.get_and_update(counts, key, &{(&1 || 0) + 1, (&1 || 0) + 1})
      end)

    if count <= limit, do: {:allow, count}, else: {:deny, window}
  end
end

defmodule ManaCoreTest.Ping do
  @moduledoc false
  use Ash.Resource, domain: ManaCoreTest.Domain, extensions: [Mana.Resource]

  access do
    public(:ping, rate_limit: "2 per minute per ip")
    public(:pong, rate_limit: :none, reason: "idempotent probe")
  end

  actions do
    action :ping, :string do
      run(fn _, _ -> {:ok, "pong"} end)
    end

    action :pong, :string do
      run(fn _, _ -> {:ok, "ping"} end)
    end
  end
end

defmodule ManaCoreTest.Part do
  @moduledoc false
  use Ash.Resource, data_layer: :embedded
  use Mana.Shape

  attributes do
    attribute(:label, :string, allow_nil?: false, public?: true)
  end
end

defmodule ManaCoreTest.Gizmo do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("gizmo")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:parts, {:array, ManaCoreTest.Part}, public?: true)
  end

  actions do
    defaults([:read])
  end
end

defmodule ManaCoreTest.Secret do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource]

  retention do
    delete_after(:expires_at, days: 30)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:expires_at, :utc_datetime_usec, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:expires_at]])
  end
end

defmodule ManaCoreTest.Color do
  @moduledoc false
  use Mana.Enum, values: [:red, :blue]
end

defmodule ManaCoreTest.Person do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource]

  privacy do
    subject(:id)
    export([:email])
    erase(:delete)
  end

  attributes do
    uuid_primary_key(:id, writable?: true)
    attribute(:email, :string, public?: true)
    attribute(:password_hash, :string)
  end

  actions do
    defaults([:read, :destroy, create: [:id, :email, :password_hash]])
  end
end

defmodule ManaCoreTest.Note do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource]

  privacy do
    subject(:person_id)
    export([:body, :color])
    erase(:delete)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:person_id, :uuid, public?: true)
    attribute(:body, :string, public?: true)
    attribute(:color, ManaCoreTest.Color, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:person_id, :body, :color]])
  end
end

defmodule ManaCoreTest.Receipt do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource]

  privacy do
    subject(:person_id)
    export([:cents])
    erase(:keep)
    reason("tax records")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:person_id, :uuid, public?: true)
    attribute(:cents, :integer, public?: true)
  end

  actions do
    defaults([:read, create: [:person_id, :cents]])
  end
end

defmodule ManaCoreTest.Ticket do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.Views],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      public?: true
    )
  end

  actions do
    defaults([:read, create: [:owner_id, :status]])
    update(:close, change: set_attribute(:status, :closed))
    update(:reopen, change: set_attribute(:status, :open))
    update(:escalate)
    update(:claim)

    read :queue do
      prepare({Mana.Views.Load, view: :row})
    end

    update :rename do
      argument(:title, :string,
        allow_nil?: false,
        constraints: [min_length: 3, max_length: 20, match: ~r/^[a-z]/]
      )

      argument(:copies, :integer, default: 1, constraints: [min: 1, max: 5])

      argument(:tags, {:array, :atom},
        constraints: [items: [one_of: [:bug, :idea]], max_length: 3]
      )

      argument(:due, :utc_datetime)
      argument(:on, :date)
    end
  end

  views do
    view(:row, fields: [:status, :verbs], live: true, describe: "a ticket in the queue")
  end

  verbs do
    verb(:close, when: expr(status == :open), inverse: :reopen, feature: "support/tickets")
    verb(:reopen, when: expr(status == :closed), unavailable: :taken)
    verb(:escalate, risk: :money, idempotent: true, retry: 2)
    verb(:claim, when: expr(status == :open and owner_id == ^actor(:id)))
  end

  policies do
    policy action_type(:read) do
      authorize_if(always())
    end

    policy action_type(:create) do
      authorize_if(always())
    end

    policy action([:close, :reopen]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end

    policy action(:escalate) do
      authorize_if(actor_attribute_equals(:role, :agent))
    end

    policy action(:claim) do
      authorize_if(always())
    end
  end
end

defmodule ManaCoreTest.Reply do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)
    attribute(:ticket_id, :uuid, allow_nil?: false, public?: true)
    attribute(:body, :string, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read])
    create(:post, accept: [:ticket_id, :body])
    create(:announce, accept: [:ticket_id, :body])

    action :digest, :string do
      run(fn _, _ -> {:ok, "digest"} end)
    end
  end

  verbs do
    verb(:post,
      collection: true,
      from: {ManaCoreTest.Ticket, :ticket_id},
      when: expr(status == :open),
      describe: "Reply to an open ticket"
    )

    verb(:announce,
      collection: true,
      when: {ManaCoreTest.Reply, :staff?},
      describe: "Post an announcement"
    )

    verb(:digest,
      collection: true,
      when: {ManaCoreTest.Reply, :staff?},
      describe: "Summarize the replies"
    )
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  def staff?(actor), do: actor && Map.get(actor, :role) == :agent
end

defmodule ManaCoreTest.Broadcast do
  @moduledoc false
  def broadcast(topic, event, payload),
    do: send(Application.get_env(:mana_core, :test_pid), {:broadcast, topic, event, payload})
end

defmodule ManaCoreTest.Sender do
  @moduledoc false
  @behaviour Mana.Notifications.Sender
  def deliver(notice) do
    send(Application.get_env(:mana_core, :test_pid), {:notice, Map.delete(notice, :record)})
    if notice.channels == [:push], do: {:error, :no_device}, else: :ok
  end

  def allows?(_user, _category, channel),
    do: channel not in Application.get_env(:mana_core, :muted, [])

  def quiet(_user), do: Application.get_env(:mana_core, :quiet_until)
end

defmodule ManaCoreTest.Rules do
  @moduledoc false
  def has_buyer?(order), do: if(order.buyer_id, do: true, else: {false, "paid without a buyer"})

  def adopt(order),
    do:
      Ash.update!(order, %{buyer_id: Application.get_env(:mana_core, :adopter)},
        action: :adopt,
        authorize?: false
      )
end

defmodule ManaCoreTest.Order do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Entity, Mana.Notifications, Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)
    attribute(:buyer_id, :uuid, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :paid, :expired]],
      default: :open,
      public?: true
    )
  end

  actions do
    defaults([:read, :destroy, create: [:buyer_id, :status]])
    update(:pay, change: set_attribute(:status, :paid))
    update(:expire, change: set_attribute(:status, :expired))
    update(:adopt, accept: [:buyer_id])
  end

  reconcile do
    desired(:paid_has_buyer, "every paid order has a buyer",
      scope: expr(status == :paid),
      holds: {ManaCoreTest.Rules, :has_buyer?},
      apply: {ManaCoreTest.Rules, :adopt}
    )
  end

  entity do
    broadcast(ManaCoreTest.Broadcast)
    audience([:buyer_id])
    watchers({ManaCoreTest.Stuck, :staff?})
    deadline(:unpaid, action: :expire, when: expr(status == :open), after: {30, :minute})
  end

  notifications do
    sender(ManaCoreTest.Sender)
    preferences({ManaCoreTest.Sender, :allows?})
    quiet_hours({ManaCoreTest.Sender, :quiet})

    notify(:pay,
      to: :counterpart,
      template: "order.paid",
      category: :orders,
      opens: "/orders/:id",
      channels: [:inbox, :email],
      payload: [:status, :buyer_id]
    )

    notify(:adopt,
      to: :buyer_id,
      template: "order.adopted",
      channels: [:inbox, :push, :email, :sms],
      fallback: true
    )

    notify(:expire,
      to: :buyer_id,
      template: "order.expired",
      when: expr(status == :expired and not is_nil(buyer_id))
    )
  end
end

defmodule ManaCoreTest.Upload do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Uploads]

  uploads do
    kind(:photo, max_bytes: 1_000)
    kind(:paper, accept: ["application/pdf"])
  end
end

defmodule ManaCoreTest.Listing do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource, Mana.Attachments]

  json_api do
    type("listing")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:cover_id, :uuid, public?: true)
    attribute(:gallery_ids, {:array, :uuid}, default: [], public?: true)
  end

  actions do
    defaults([:read, create: [:cover_id, :gallery_ids]])

    update :update do
      primary?(true)
      require_atomic?(false)
      accept([:cover_id, :gallery_ids])
    end

    update(:touch)
  end

  attachments do
    files(ManaCoreTest.Upload)
    attach(:cover_id, kinds: [:photo])
    attach(:gallery_ids, kinds: [:paper])
  end

  calculations do
    calculate(:cover_url, :string, {Mana.Uploads.Url, attribute: :cover_id}, public?: true)

    calculate(:files, {:array, :map}, {Mana.Uploads.Urls, attributes: [:cover_id, :gallery_ids]},
      public?: true
    )
  end
end

defmodule ManaCoreTest.HistoryEntry do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.History.Log]

  history_log do
    subjects([ManaCoreTest.Task, ManaCoreTest.Signup, ManaCoreTest.Diary])
  end
end

defmodule ManaCoreTest.Task do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource, Mana.Verbs, Mana.Views, Mana.History],
    authorizers: [Ash.Policy.Authorizer]

  json_api do
    type("task")
  end

  views do
    view(:card, fields: [:title, :status, :verbs], entry: :read, describe: "a task in the list")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:secret, :string, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :done]],
      default: :open,
      public?: true
    )
  end

  actions do
    defaults([:read, create: [:owner_id, :title, :secret]])

    update :finish do
      accept([:secret])
      argument(:note, :string)
      validate(attribute_equals(:status, :open), message: "already finished")
      change(set_attribute(:status, :done))
    end

    update :touch
    update(:reopen, change: set_attribute(:status, :open))
    update :archive

    update :explode do
      validate(attribute_equals(:title, "never"))
    end

    update :pin
  end

  verbs do
    verb(:finish, when: expr(status == :open), narrate: "finished the task", inverse: :reopen)
    verb(:reopen, when: expr(status == :done))
    verb(:archive, feature: "tasks/archive")
    verb(:explode)
    verb(:pin, knob: :pinning)
  end

  history do
    log(ManaCoreTest.HistoryEntry)
    redact([:secret])
    ignore([:touch])
  end

  policies do
    policy action_type(:read) do
      authorize_if(actor_present())
    end

    policy action_type([:create, :update]) do
      authorize_if(always())
    end
  end
end

defmodule ManaCoreTest.Diary do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource, Mana.History, Mana.Verbs, Mana.Notifications]

  privacy do
    subject(:person_id)
    export([:body])
    erase(:delete)
  end

  history do
    log(ManaCoreTest.HistoryEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:person_id, :uuid, public?: true)
    attribute(:body, :string, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:person_id, :body], update: [:body]])
    update(:mail)

    update :crash do
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.before_action(changeset, fn _ -> raise "provider down" end)
      end)
    end
  end

  verbs do
    verb(:mail, external: "email")
  end

  notifications do
    sender(ManaCoreTest.Sender)

    notify(:mail,
      to: :person_id,
      template: "diary.mailed",
      channels: [:inbox, :push, :email],
      fallback: true
    )
  end
end

defmodule ManaCoreTest.Place do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Resource]

  privacy do
    subject(:owner_id)
    export([:name])
    erase(:detach)
    reason("bookings still name the place")
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:public, :boolean, default: true, public?: true)
  end

  actions do
    defaults([:read, create: [:owner_id, :name]])

    update :detach do
      change(set_attribute(:owner_id, nil))
      change(set_attribute(:public, false))
    end
  end
end

defmodule ManaCoreTest.Stuck do
  @moduledoc false
  def staff?(user), do: Map.get(user, :role) == :staff

  def report(failure, _error) do
    send(Application.get_env(:mana_core, :test_pid), {:reported, failure})
    "evt-1"
  end

  def called(record, step),
    do: send(Application.get_env(:mana_core, :test_pid), {:stuck, record.id, step})
end

defmodule ManaCoreTest.Signup do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshJsonApi.Resource, Mana.Flow, Mana.History, Mana.Verbs]

  json_api do
    type("signup")
  end

  history do
    log(ManaCoreTest.HistoryEntry)
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:stage, :atom,
      constraints: [one_of: [:demo, :terms, :details, :address, :done]],
      default: :terms,
      public?: true
    )

    attribute(:kind, :atom,
      constraints: [one_of: [:place, :virtual]],
      default: :place,
      public?: true
    )
  end

  actions do
    defaults([:read, create: [:stage, :kind]])

    update :accept_terms do
      require_atomic?(false)
    end

    update :relabel do
      accept([:kind])
    end

    update :save_details do
      require_atomic?(false)
      accept([:kind])
    end

    update :save_address do
      require_atomic?(false)
    end
  end

  verbs do
    verb(:accept_terms)
    verb(:save_details)
    verb(:save_address)
  end

  flow do
    cursor(:stage)
    before([:demo])
    step(:terms, action: :accept_terms)

    step(:details,
      action: :save_details,
      attempts: [:details_checked, :mail_sent],
      bugs: [:mail_sent]
    )

    step(:address, action: :save_address, skip_if: expr(kind == :virtual))
    done(:done)
    stuck_after({1, :day})
    on_stuck({ManaCoreTest.Stuck, :called})
  end
end

defmodule ManaCoreTest.KnobValue do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Knobs.Store]
end

defmodule ManaCoreTest.Knobs do
  @moduledoc false
  use Mana.Knobs, store: ManaCoreTest.KnobValue

  def configured, do: Application.get_env(:mana_core, :pinning_default, false)

  knob(:pinning, :boolean,
    default: {__MODULE__, :configured, []},
    feature: "tasks",
    describe: "Pin tasks"
  )

  knob(:page_size, :integer, default: 20)
  knob(:archiving, :boolean, default: true, enables: "tasks/archive")
end

defmodule ManaCoreTest.Pricing do
  @moduledoc false
  use Mana.Examples

  defexample total(lines, %{rate: rate}) do
    Enum.sum(lines) * rate
  end
end

defmodule ManaCoreTest.Mention do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Notifications]

  attributes do
    uuid_primary_key(:id)
    attribute(:names, {:array, :string}, public?: true)
  end

  actions do
    defaults([:read, create: [:names]])
  end

  notifications do
    sender(ManaCoreTest.Sender)

    notify(:create,
      to: {ManaCoreTest.Mention, :mentioned},
      template: "mention.new",
      payload: {ManaCoreTest.Mention, :about}
    )
  end

  def mentioned(mention), do: Enum.map(mention.names, &"user-#{&1}")
  def about(mention), do: %{count: length(mention.names)}
end

defmodule ManaCoreTest.Alert do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Notifications]

  attributes do
    uuid_primary_key(:id)
    attribute(:user_id, :uuid, public?: true)
  end

  actions do
    defaults([:read, create: [:user_id]])
  end

  notifications do
    sender(ManaCoreTest.Sender)
    group_within({1, :minute})
    notify(:create, to: :user_id, template: "alert.raised", channels: [:inbox, :email])
  end
end

defmodule ManaCoreTest.Slot do
  @moduledoc false
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs]

  attributes do
    uuid_primary_key(:id)
    attribute(:group, :string, allow_nil?: false, public?: true)
  end

  relationships do
    has_many(:group_slots, __MODULE__, source_attribute: :group, destination_attribute: :group)
  end

  aggregates do
    count(:group_size, :group_slots)
  end

  actions do
    defaults([:read, create: [:group]])

    destroy :remove do
      require_atomic?(false)
    end
  end

  verbs do
    verb(:remove, risk: :destructive, when: expr(group_size > 1))
  end
end

defmodule ManaCoreTest.Book do
  @moduledoc false
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets

  multitenancy do
    strategy(:attribute)
    attribute(:org)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org, :string, allow_nil?: false, public?: true)
  end

  relationships do
    belongs_to(:shelf, ManaCoreTest.Shelf, allow_nil?: false, public?: true)
  end

  actions do
    defaults([:read, :destroy, create: [:shelf_id]])
  end
end

defmodule ManaCoreTest.Shelf do
  @moduledoc false
  # A multitenant resource whose verb asks an aggregate: deciding it reads the stored rows,
  # which only exist in the record's tenant.
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs]

  multitenancy do
    strategy(:attribute)
    attribute(:org)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org, :string, allow_nil?: false, public?: true)

    attribute(:status, :atom,
      constraints: [one_of: [:open, :closed]],
      default: :open,
      public?: true
    )
  end

  relationships do
    has_many(:books, ManaCoreTest.Book)
  end

  aggregates do
    count(:books_left, :books)
  end

  actions do
    defaults([:read, create: [:status]])

    # Not atomic: the ETS data layer would run an atomic update's validation without the tenant.
    update :close do
      require_atomic?(false)
      change(set_attribute(:status, :closed))
    end
  end

  verbs do
    verb(:close, when: expr(status == :open and books_left == 0))
  end
end

defmodule ManaCoreTest.Domain do
  @moduledoc false
  use Ash.Domain, extensions: [Mana.Domain], validate_config_inclusion?: false

  resources do
    resource(ManaCoreTest.Slot)
    resource(ManaCoreTest.Ping)
    resource(ManaCoreTest.Secret)
    resource(ManaCoreTest.Person)
    resource(ManaCoreTest.Note)
    resource(ManaCoreTest.Receipt)
    resource(ManaCoreTest.Gizmo)
    resource(ManaCoreTest.Ticket)
    resource(ManaCoreTest.Reply)
    resource(ManaCoreTest.Order)
    resource(ManaCoreTest.Upload)
    resource(ManaCoreTest.Listing)
    resource(ManaCoreTest.HistoryEntry)
    resource(ManaCoreTest.Task)
    resource(ManaCoreTest.Signup)
    resource(ManaCoreTest.Diary)
    resource(ManaCoreTest.Place)
    resource(ManaCoreTest.KnobValue)
    resource(ManaCoreTest.Alert)
    resource(ManaCoreTest.Mention)
    resource(ManaCoreTest.Shelf)
    resource(ManaCoreTest.Book)
  end

  errors do
    error(:taken, "demo.taken", status: 409, message: "already taken")
  end
end
