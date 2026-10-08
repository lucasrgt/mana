defmodule ManaCoreTest.Limiter do
  def start, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def hit(key, window, limit) do
    count = Agent.get_and_update(__MODULE__, fn counts -> Map.get_and_update(counts, key, &{(&1 || 0) + 1, (&1 || 0) + 1}) end)
    if count <= limit, do: {:allow, count}, else: {:deny, window}
  end
end

defmodule ManaCoreTest.Ping do
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
  use Ash.Resource, data_layer: :embedded
  use Mana.Shape

  attributes do
    attribute(:label, :string, allow_nil?: false, public?: true)
  end
end

defmodule ManaCoreTest.Gizmo do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [AshJsonApi.Resource]

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
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Resource]

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
  use Mana.Enum, values: [:red, :blue]
end

defmodule ManaCoreTest.Person do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Resource]

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
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Resource]

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
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Resource]

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
  use Ash.Resource,
    domain: ManaCoreTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Verbs, Mana.Views],
    authorizers: [Ash.Policy.Authorizer]

  attributes do
    uuid_primary_key(:id)
    attribute(:owner_id, :uuid, allow_nil?: false, public?: true)
    attribute(:status, :atom, constraints: [one_of: [:open, :closed]], default: :open, public?: true)
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
      argument(:title, :string, allow_nil?: false, constraints: [min_length: 3, max_length: 20, match: ~r/^[a-z]/])
      argument(:copies, :integer, default: 1, constraints: [min: 1, max: 5])
      argument(:tags, {:array, :atom}, constraints: [items: [one_of: [:bug, :idea]], max_length: 3])
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
    verb(:post, collection: true, from: {ManaCoreTest.Ticket, :ticket_id}, when: expr(status == :open), describe: "Reply to an open ticket")
    verb(:announce, collection: true, when: {ManaCoreTest.Reply, :staff?}, describe: "Post an announcement")
    verb(:digest, collection: true, when: {ManaCoreTest.Reply, :staff?}, describe: "Summarize the replies")
  end

  policies do
    policy always() do
      authorize_if(always())
    end
  end

  def staff?(actor), do: actor && Map.get(actor, :role) == :agent
end

defmodule ManaCoreTest.Broadcast do
  def broadcast(topic, event, payload), do: send(Application.get_env(:mana_core, :test_pid), {:broadcast, topic, event, payload})
end

defmodule ManaCoreTest.Sender do
  @behaviour Mana.Notifications.Sender
  def deliver(notice) do
    send(Application.get_env(:mana_core, :test_pid), {:notice, Map.delete(notice, :record)})
    if notice.channels == [:push], do: {:error, :no_device}, else: :ok
  end

  def allows?(_user, _category, channel), do: channel not in Application.get_env(:mana_core, :muted, [])
  def quiet(_user), do: Application.get_env(:mana_core, :quiet_until)
end

defmodule ManaCoreTest.Rules do
  def has_buyer?(order), do: if(order.buyer_id, do: true, else: {false, "paid without a buyer"})
  def adopt(order), do: Ash.update!(order, %{buyer_id: Application.get_env(:mana_core, :adopter)}, action: :adopt, authorize?: false)
end

defmodule ManaCoreTest.Order do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Entity, Mana.Notifications, Mana.Reconcile]

  attributes do
    uuid_primary_key(:id)
    attribute(:buyer_id, :uuid, public?: true)
    attribute(:status, :atom, constraints: [one_of: [:open, :paid, :expired]], default: :open, public?: true)
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
    notify(:pay, to: :counterpart, template: "order.paid", category: :orders, opens: "/orders/:id", channels: [:inbox, :email], payload: [:status, :buyer_id])
    notify(:adopt, to: :buyer_id, template: "order.adopted", channels: [:inbox, :push, :email, :sms], fallback: true)
    notify(:expire, to: :buyer_id, template: "order.expired", when: expr(status == :expired and not is_nil(buyer_id)))
  end
end

defmodule ManaCoreTest.Upload do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Uploads]

  uploads do
    kind(:photo, max_bytes: 1_000)
    kind(:paper, accept: ["application/pdf"])
  end
end

defmodule ManaCoreTest.Listing do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [AshJsonApi.Resource, Mana.Attachments]

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
    calculate(:files, {:array, :map}, {Mana.Uploads.Urls, attributes: [:cover_id, :gallery_ids]}, public?: true)
  end
end

defmodule ManaCoreTest.HistoryEntry do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.History.Log]

  history_log do
    subjects([ManaCoreTest.Task, ManaCoreTest.Signup, ManaCoreTest.Diary])
  end
end

defmodule ManaCoreTest.Task do
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
    attribute(:status, :atom, constraints: [one_of: [:open, :done]], default: :open, public?: true)
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
    verb(:archive)
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
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Resource, Mana.History, Mana.Verbs]

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
  end

  verbs do
    verb(:mail, external: "email")
  end
end

defmodule ManaCoreTest.Place do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Resource]

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
  def staff?(user), do: Map.get(user, :role) == :staff
  def called(record, step), do: send(Application.get_env(:mana_core, :test_pid), {:stuck, record.id, step})
end

defmodule ManaCoreTest.Signup do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [AshJsonApi.Resource, Mana.Flow, Mana.History, Mana.Verbs]

  json_api do
    type("signup")
  end

  history do
    log(ManaCoreTest.HistoryEntry)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:stage, :atom, constraints: [one_of: [:demo, :terms, :details, :address, :done]], default: :terms, public?: true)
    attribute(:kind, :atom, constraints: [one_of: [:place, :virtual]], default: :place, public?: true)
  end

  actions do
    defaults([:read, create: [:stage, :kind]])

    update :accept_terms do
      require_atomic?(false)
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
    step(:details, action: :save_details)
    step(:address, action: :save_address, skip_if: expr(kind == :virtual))
    done(:done)
    stuck_after({1, :day})
    on_stuck({ManaCoreTest.Stuck, :called})
  end
end

defmodule ManaCoreTest.KnobValue do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Knobs.Store]
end

defmodule ManaCoreTest.Knobs do
  use Mana.Knobs, store: ManaCoreTest.KnobValue

  def configured, do: Application.get_env(:mana_core, :pinning_default, false)

  knob(:pinning, :boolean, default: {__MODULE__, :configured, []}, feature: "tasks", describe: "Pin tasks")
  knob(:page_size, :integer, default: 20)
end

defmodule ManaCoreTest.Pricing do
  use Mana.Examples

  defexample total(lines, %{rate: rate}) do
    Enum.sum(lines) * rate
  end
end

defmodule ManaCoreTest.Mention do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Notifications]

  attributes do
    uuid_primary_key(:id)
    attribute(:names, {:array, :string}, public?: true)
  end

  actions do
    defaults([:read, create: [:names]])
  end

  notifications do
    sender(ManaCoreTest.Sender)
    notify(:create, to: {ManaCoreTest.Mention, :mentioned}, template: "mention.new", payload: {ManaCoreTest.Mention, :about})
  end

  def mentioned(mention), do: Enum.map(mention.names, &"user-#{&1}")
  def about(mention), do: %{count: length(mention.names)}
end

defmodule ManaCoreTest.Alert do
  use Ash.Resource, domain: ManaCoreTest.Domain, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Notifications]

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

defmodule ManaCoreTest.Domain do
  use Ash.Domain, extensions: [Mana.Domain], validate_config_inclusion?: false

  resources do
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
  end

  errors do
    error(:taken, "demo.taken", status: 409, message: "already taken")
  end
end

defmodule ManaCoreTest do
  use ExUnit.Case, async: false

  setup_all do
    Application.put_env(:mana_core, :knobs, ManaCoreTest.Knobs)
    Application.put_env(:mana_core, :knob_ttl_ms, 0)
    ManaCoreTest.Limiter.start()
    Application.put_env(:mana_core, :limiter, ManaCoreTest.Limiter)
    :ok
  end

  defp compile(source) do
    Code.compile_string(source)
    :ok
  rescue
    error -> {:error, Exception.message(error)}
  end

  test "a domain builds its declared errors with code and status" do
    error = ManaCoreTest.Domain.error(:taken)
    assert %Mana.Error{code: "demo.taken", status: 409, message: "already taken"} = error
    assert ManaCoreTest.Domain.error(:taken, field: :email).field == :email
    assert_raise ArgumentError, fn -> ManaCoreTest.Domain.error(:missing) end
    assert Mana.Domain.Info.codes([ManaCoreTest.Domain]) == ["demo.taken"]
  end

  test "error codes must be namespaced, unique and 4xx" do
    domain = fn errors ->
      """
      defmodule ManaCoreTest.Bad#{System.unique_integer([:positive])} do
        use Ash.Domain, extensions: [Mana.Domain], validate_config_inclusion?: false
        errors do
      #{errors}
        end
      end
      """
    end

    assert {:error, message} = compile(domain.(~s|error :a, "flat", status: 409, message: "x"|))
    assert message =~ "area.reason"

    assert {:error, message} =
             compile(domain.(~s|error :a, "x.y", status: 409, message: "x"\nerror :b, "x.y", status: 400, message: "y"|))

    assert message =~ "declared twice"
    assert {:error, _} = compile(domain.(~s|error :a, "x.y", status: 500, message: "x"|))
  end

  test "public actions must decide their rate limit; opting out needs a reason" do
    resource = fn access ->
      """
      defmodule ManaCoreTest.R#{System.unique_integer([:positive])} do
        use Ash.Resource, domain: nil, extensions: [Mana.Resource], validate_domain_inclusion?: false
        access do
      #{access}
        end
        actions do
          action :go, :string do
            run fn _, _ -> {:ok, "x"} end
          end
        end
      end
      """
    end

    assert :ok = compile(resource.(~s|public :go, rate_limit: "1 per second per actor"|))
    assert {:error, _} = compile(resource.(~s|public :go|))
    assert {:error, message} = compile(resource.(~s|public :go, rate_limit: :none|))
    assert message =~ "reason"
    assert {:error, message} = compile(resource.(~s|public :go, rate_limit: "lots"|))
    assert message =~ "per minute"
    assert {:error, message} = compile(resource.(~s|limit :nope, "1 per hour per ip"|))
    assert message =~ "not an action"
  end

  test "a limited action refuses calls over budget, keyed by source" do
    call = fn action, ip ->
      ManaCoreTest.Ping
      |> Ash.ActionInput.for_action(action, %{}, context: %{mana: %{ip: ip}})
      |> Ash.run_action()
    end

    assert {:ok, "pong"} = call.(:ping, "10.0.0.1")
    assert {:ok, "pong"} = call.(:ping, "10.0.0.1")
    assert {:error, %Ash.Error.Invalid{errors: [error]}} = call.(:ping, "10.0.0.1")
    assert %Mana.Error{code: "platform.rate_limited", status: 429, meta: %{retry_after: 60}} = error
    assert {:ok, "pong"} = call.(:ping, "10.0.0.2")
    for _ <- 1..5, do: assert({:ok, "ping"} = call.(:pong, "10.0.0.1"))

    Application.put_env(:mana_core, :rate_limits?, false)
    on_exit(fn -> Application.delete_env(:mana_core, :rate_limits?) end)
    assert {:ok, "pong"} = call.(:ping, "10.0.0.1")
  end

  defmodule Sms do
    use Mana.Integration, otp_app: :mana_core
    @callback send_code(String.t()) :: :ok
    def send_code(phone), do: adapter().send_code(phone)
  end

  defmodule Sms.Fake do
    use Mana.Integration.Adapter, slot: ManaCoreTest.Sms, fake: true
    def send_code(_), do: :ok
  end

  defmodule Sms.Real do
    use Mana.Integration.Adapter, slot: ManaCoreTest.Sms, env: ["MANA_TEST_SMS_KEY"]
    def send_code(_), do: :ok
  end

  test "integrations refuse fakes and missing credentials only in production" do
    Application.put_env(:mana_core, Sms, adapter: Sms.Fake)
    assert :ok = Sms.send_code("+5511")
    assert :ok = Mana.Integration.check!([Sms], false)
    assert_raise ArgumentError, ~r/fake adapter/, fn -> Mana.Integration.check!([Sms], true) end

    Application.put_env(:mana_core, Sms, adapter: Sms.Real)
    System.delete_env("MANA_TEST_SMS_KEY")
    assert_raise ArgumentError, ~r/MANA_TEST_SMS_KEY is not set/, fn -> Mana.Integration.check!([Sms], true) end
    System.put_env("MANA_TEST_SMS_KEY", "k")
    assert :ok = Mana.Integration.check!([Sms], true)
    assert Sms.Real.env!("MANA_TEST_SMS_KEY") == "k"
    assert_raise ArgumentError, fn -> Sms.Real.env!("OTHER") end

    Application.put_env(:mana_core, Sms, adapter: ManaCoreTest)
    assert_raise ArgumentError, ~r/not a Mana.Integration.Adapter/, fn -> Mana.Integration.check!([Sms], false) end
  end

  test "retention deletes rows past the declared age and keeps the rest" do
    at = fn days -> DateTime.add(DateTime.utc_now(), -days, :day) end
    for days <- [31, 29, 0], do: Ash.create!(ManaCoreTest.Secret, %{expires_at: at.(days)})
    assert Mana.Retention.purge([ManaCoreTest.Domain]) == 1
    assert length(Ash.read!(ManaCoreTest.Secret)) == 2

    bad = """
    defmodule ManaCoreTest.BadRetention do
      use Ash.Resource, domain: nil, extensions: [Mana.Resource], validate_domain_inclusion?: false
      retention do
        delete_after :name, days: 1
      end
      attributes do
        uuid_primary_key :id
        attribute :name, :string
      end
      actions do
        defaults [:destroy]
      end
    end
    """

    assert {:error, message} = compile(bad)
    assert message =~ "datetime attribute"
  end

  test "route patterns match parameters but not prefixes" do
    routes = [{"POST", ["api", "account", "register"]}, {"DELETE", ["api", "sessions", ":id"]}]
    assert Mana.Router.match?(%{method: "POST", path_info: ["api", "account", "register"]}, routes)
    assert Mana.Router.match?(%{method: "DELETE", path_info: ["api", "sessions", "abc"]}, routes)
    refute Mana.Router.match?(%{method: "GET", path_info: ["api", "account", "register"]}, routes)
    refute Mana.Router.match?(%{method: "DELETE", path_info: ["api", "sessions"]}, routes)
  end

  test "local storage serves only correctly signed, unexpired URLs" do
    root = Path.join(System.tmp_dir!(), "mana-storage-#{System.unique_integer([:positive])}")
    Application.put_env(:mana_core, Mana.Storage,
      adapter: Mana.Storage.Local, root: root, base_url: "http://local/__storage", secret: "test-secret")

    call = fn method, url, body ->
      %{path: "/__storage/" <> path, query: query} = URI.parse(url)
      Plug.Test.conn(method, "/" <> path <> "?" <> query, body)
      |> Map.put(:path_info, String.split(path, "/"))
      |> Mana.Storage.LocalPlug.call([])
    end

    upload = Mana.Storage.upload_url("photos/a.jpg", "image/jpeg", 60)
    assert upload.method == "PUT"
    assert call.(:put, upload.url, "jpeg-bytes").status == 200
    read = Mana.Storage.read_url("photos/a.jpg", 600)
    assert read == Mana.Storage.read_url("photos/a.jpg", 600)
    assert call.(:get, read, nil).resp_body == "jpeg-bytes"
    assert call.(:get, String.replace(read, "photos/a.jpg", "photos/b.jpg"), nil).status == 403
    assert call.(:put, read, "x").status == 403
    assert_raise ArgumentError, fn -> Mana.Storage.read_url("../etc/passwd") end
    assert :ok = Mana.Storage.delete("photos/a.jpg")
    refute Mana.Storage.exists?("photos/a.jpg")
  end

  test "erasing a person detaches the rows other records still name" do
    id = Ash.UUID.generate()
    place = Ash.create!(ManaCoreTest.Place, %{owner_id: id, name: "Camping"})
    Mana.Privacy.erase([ManaCoreTest.Domain], id)
    assert %{owner_id: nil, public: false, name: "Camping"} = Ash.get!(ManaCoreTest.Place, place.id)
  end

  test "erasing a person drops the history of their records and forgets them as the actor elsewhere" do
    id = Ash.UUID.generate()
    person = %{id: id}
    diary = Ash.create!(ManaCoreTest.Diary, %{person_id: id, body: "mine"}, actor: person)
    Ash.update!(diary, %{body: "still mine"}, actor: person)
    task = Ash.create!(ManaCoreTest.Task, %{owner_id: Ash.UUID.generate(), title: "shared"}, actor: person)

    Mana.Privacy.erase([ManaCoreTest.Domain], id)

    entries = Ash.read!(ManaCoreTest.HistoryEntry)
    refute Enum.any?(entries, &(&1.subject_type == "diary" and &1.subject_id == to_string(diary.id)))
    assert [%{actor_id: nil, via: "erased", actor_kind: :user}] = Enum.filter(entries, &(&1.subject_id == to_string(task.id)))
  end

  test "privacy exports declared projections and erases all but kept rows" do
    id = Ash.UUID.generate()
    other = Ash.UUID.generate()
    Ash.create!(ManaCoreTest.Person, %{id: id, email: "a@x", password_hash: "secret"})
    Ash.create!(ManaCoreTest.Note, %{person_id: id, body: "mine", color: :red})
    Ash.create!(ManaCoreTest.Note, %{person_id: other, body: "theirs"})
    Ash.create!(ManaCoreTest.Receipt, %{person_id: id, cents: 100})

    assert %{"person" => [%{email: "a@x"} = person], "note" => [%{body: "mine", color: :red}], "receipt" => [%{cents: 100}]} =
             Mana.Privacy.export([ManaCoreTest.Domain], id)

    refute Map.has_key?(person, :password_hash)

    Mana.Privacy.erase([ManaCoreTest.Domain], id)
    assert Ash.read!(ManaCoreTest.Person) == []
    assert [%{body: "theirs"}] = Ash.read!(ManaCoreTest.Note)
    assert [%{cents: 100}] = Ash.read!(ManaCoreTest.Receipt)

    resource = fn privacy ->
      """
      defmodule ManaCoreTest.P#{System.unique_integer([:positive])} do
        use Ash.Resource, domain: nil, extensions: [Mana.Resource], validate_domain_inclusion?: false
        privacy do
      #{privacy}
        end
        attributes do
          uuid_primary_key :id
          attribute :owner_id, :uuid
        end
        actions do
          defaults [:read, :destroy]
        end
      end
      """
    end

    assert :ok = compile(resource.("subject :owner_id\nerase :delete"))
    assert {:error, message} = compile(resource.("subject :owner_id\nerase :keep"))
    assert message =~ "reason"
    assert {:error, message} = compile(resource.("subject :nobody\nerase :delete"))
    assert message =~ "must be an attribute"
    assert {:error, message} = compile(resource.("subject :owner_id\nexport [:ssn]\nerase :delete"))
    assert message =~ ":ssn"
  end

  test "a Mana.Shape is one component for its read copy and its create and update inputs" do
    create = %{"type" => "object", "properties" => %{"label" => %{"type" => "string"}}, "required" => ["label"]}
    ref = &%{"$ref" => "#/components/schemas/#{&1}"}

    spec = %{
      "components" => %{
        "schemas" => %{
          "gizmo_parts-input-create-type" => create,
          "gizmo_parts-input-update-type" => %{"type" => "object"},
          "gizmo" => %{"properties" => %{"attributes" => %{"properties" => %{"parts" => %{"type" => "array", "items" => create}}}}}
        }
      },
      "paths" => %{"/gizmos" => %{"post" => ref.("gizmo_parts-input-create-type"), "patch" => ref.("gizmo_parts-input-update-type")}}
    }

    shaped = Mana.Domain.OpenApi.put_shapes(spec, [ManaCoreTest.Domain])
    schemas = shaped["components"]["schemas"]
    assert schemas["Part"] == create
    refute Map.has_key?(schemas, "gizmo_parts-input-create-type") or Map.has_key?(schemas, "gizmo_parts-input-update-type")
    assert schemas["gizmo"]["properties"]["attributes"]["properties"]["parts"]["items"] == ref.("Part")
    assert shaped["paths"]["/gizmos"] == %{"post" => ref.("Part"), "patch" => ref.("Part")}
  end

  test "a Mana.Enum becomes one named component wherever it appears" do
    assert %{enum: ["red", "blue"], extensions: %{"x-mana-enum" => "Color"}} = ManaCoreTest.Color.json_schema([])
    inline = ManaCoreTest.Color.json_write_schema([])

    spec = %{
      "components" => %{"schemas" => %{}},
      "paths" => %{"/a" => %{"get" => %{"schema" => %{"items" => inline}, "other" => inline}}}
    }

    hoisted = Mana.Domain.OpenApi.put_enums(spec)
    assert hoisted["paths"]["/a"]["get"]["other"] == %{"$ref" => "#/components/schemas/Color"}
    assert hoisted["components"]["schemas"]["Color"] == %{"type" => "string", "enum" => ["red", "blue"]}
  end

  test "what every read returns stays required and non-null in a shape an input made optional" do
    create = %{"type" => "object", "properties" => %{"label" => %{"type" => "string", "nullable" => true}}, "required" => []}
    read = %{"type" => "object", "properties" => %{"label" => %{"type" => "string"}}, "required" => ["label"]}

    spec = %{
      "components" => %{
        "schemas" => %{
          "gizmo_parts-input-create-type" => create,
          "gizmo" => %{"properties" => %{"attributes" => %{"properties" => %{"parts" => %{"type" => "array", "items" => read}}}}}
        }
      },
      "paths" => %{}
    }

    part = Mana.Domain.OpenApi.put_shapes(spec, [ManaCoreTest.Domain])["components"]["schemas"]["Part"]
    assert part["required"] == ["label"]
    assert part["properties"]["label"] == %{"type" => "string"}
  end

  test "alternatives that ended up identical collapse into one" do
    list = %{"type" => "array", "items" => %{"$ref" => "#/components/schemas/Part"}}
    assert Mana.Domain.OpenApi.collapse_alternatives(%{"x" => %{"anyOf" => [list, list]}}) == %{"x" => list}
    two = %{"anyOf" => [list, %{"type" => "string"}]}
    assert Mana.Domain.OpenApi.collapse_alternatives(two) == two
  end

  test "an inline object with exactly a shape's fields becomes that shape's component" do
    part = %{"type" => "object", "properties" => %{"label" => %{"type" => "string"}}}
    wider = %{"type" => "object", "properties" => %{"label" => %{"type" => "string"}, "extra" => %{"type" => "integer"}}}
    ref = %{"$ref" => "#/components/schemas/Part"}

    spec = %{
      "components" => %{"schemas" => %{"Part" => part}},
      "paths" => %{
        "/a" => %{"get" => %{"schema" => %{"type" => "array", "items" => Map.put(part, "nullable", true)}}},
        "/b" => %{"post" => %{"schema" => wider}}
      }
    }

    shaped = Mana.Domain.OpenApi.put_inline_shapes(spec, [ManaCoreTest.Domain], [ManaCoreTest.Part])
    assert shaped["paths"]["/a"]["get"]["schema"]["items"] == ref
    assert shaped["paths"]["/b"]["post"]["schema"] == wider
    assert shaped["components"]["schemas"]["Part"] == part
  end

  defmodule Hooks do
    def ok(body, _), do: send(self(), {:body, body}) && :ok
    def ignored(_, _), do: :ignored
    def later(_, _), do: {:error, :provider_down}
    def crash(_, _), do: raise("boom")
  end

  test "a webhook answers 200 when handled or ignored, 503 to be retried, 404 for an unknown hook" do
    opts =
      Mana.Webhook.init(
        at: ["webhooks"],
        handlers: %{["ok"] => &Hooks.ok/2, ["ignored"] => &Hooks.ignored/2, ["later"] => &Hooks.later/2, ["crash"] => &Hooks.crash/2}
      )

    post = &Mana.Webhook.call(Plug.Test.conn(:post, "/webhooks/#{&1}", ~s({"raw": true})), opts)

    ExUnit.CaptureLog.capture_log(fn ->
      assert post.("ok").status == 200
      assert_received {:body, ~s({"raw": true})}
      assert post.("ignored").status == 200
      assert post.("later").status == 503
      assert post.("crash").status == 503
      assert post.("missing").status == 404
    end)

    passed = Mana.Webhook.call(Plug.Test.conn(:get, "/webhooks/ok"), opts)
    refute passed.halted or passed.state == :sent
    refute Mana.Webhook.call(Plug.Test.conn(:post, "/api/ok", "{}"), opts).halted
  end

  test "a webhook signature is checked over the exact bytes, in constant time" do
    signature = :crypto.mac(:hmac, :sha256, "secret", "payload") |> Base.encode16()
    assert Mana.Webhook.hmac_sha256_valid?("secret", "payload", signature)
    refute Mana.Webhook.hmac_sha256_valid?("secret", "payload ", signature)
    refute Mana.Webhook.hmac_sha256_valid?("", "payload", signature)
    refute Mana.Webhook.hmac_sha256_valid?("secret", "payload", nil)
  end

  test "verbs offer only what the record's state and the actor's policies allow" do
    owner = %{id: Ash.UUID.generate(), role: :user}
    agent = %{id: Ash.UUID.generate(), role: :agent}
    ticket = Ash.Seed.seed!(ManaCoreTest.Ticket, %{owner_id: owner.id, status: :open})

    assert Mana.Verbs.offered(ticket, owner) == ["close", "claim", "reply.post"]
    assert Mana.Verbs.offered(ticket, agent) == ["escalate", "reply.post"]
    assert Mana.Verbs.offered(%{ticket | status: :closed}, owner) == ["reopen"]

    loaded = ManaCoreTest.Ticket |> Ash.Query.load(:verbs) |> Ash.read!(actor: owner) |> Enum.find(&(&1.id == ticket.id))
    assert loaded.verbs == ["close", "claim", "reply.post"]
  end

  test "a verb's inputs carry the rules its action enforces" do
    assert Mana.Verbs.inputs(ManaCoreTest.Ticket, :create) == [
             %{"name" => "owner_id", "required" => true, "type" => "string", "format" => "uuid"},
             %{"name" => "status", "required" => false, "type" => "string", "one_of" => ["open", "closed"]}
           ]

    assert Mana.Verbs.inputs(ManaCoreTest.Ticket, :rename) == [
             %{"name" => "title", "required" => true, "type" => "string", "min_length" => 3, "max_length" => 20, "match" => "^[a-z]"},
             %{"name" => "copies", "required" => false, "type" => "integer", "min" => 1, "max" => 5},
             %{"name" => "tags", "required" => false, "type" => "array", "max_length" => 3, "items" => %{"type" => "string", "one_of" => ["bug", "idea"]}},
             %{"name" => "due", "required" => false, "type" => "string", "format" => "date-time"},
             %{"name" => "on", "required" => false, "type" => "string", "format" => "date"}
           ]

    assert [%{"name" => "close", "inputs" => []} | _] = Mana.Verbs.contract(ManaCoreTest.Ticket)

    assert :ok =
             compile("""
             defmodule ManaCoreTest.Handle do
               use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, validate_domain_inclusion?: false
               attributes do
                 uuid_primary_key :id
                 attribute :handle, :string, allow_nil?: false, public?: true
               end
               identities do
                 identity :unique_handle, [:handle], pre_check_with: ManaCoreTest.Domain
               end
               actions do
                 defaults [:read, create: [:handle]]
               end
             end
             """)

    assert [%{"name" => "handle", "unique" => true, "required" => true}] = Mana.Verbs.inputs(ManaCoreTest.Handle, :create)
  end

  test "a verb retries or waits offline only when replaying it is safe" do
    resource = fn verb ->
      """
      defmodule ManaCoreTest.Q#{System.unique_integer([:positive])} do
        use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs], validate_domain_inclusion?: false
        attributes do
          uuid_primary_key :id
        end
        actions do
          defaults [:read]
          update :pay
        end
        verbs do
          #{verb}
        end
      end
      """
    end

    assert :ok = compile(resource.("verb :pay, idempotent: true, retry: 3, offline: :queue"))
    assert {:error, retry} = compile(resource.("verb :pay, retry: 1"))
    assert retry =~ "retries but is not idempotent"
    assert {:error, queue} = compile(resource.("verb :pay, offline: :queue"))
    assert queue =~ "queues offline but is not idempotent"
    assert {:error, money} = compile(resource.("verb :pay, idempotent: true, offline: :queue, risk: :money"))
    assert money =~ "cannot wait in an offline queue"
  end

  test "the server refuses a verb its record does not offer, with the declared error" do
    ticket = Ash.Seed.seed!(ManaCoreTest.Ticket, %{owner_id: Ash.UUID.generate(), status: :open})
    update = &Ash.update(&1, %{}, action: &2, authorize?: false)

    assert {:ok, closed} = update.(ticket, :close)
    assert {:error, %{errors: [%Mana.Error{code: "verb.unavailable", status: 422}]}} = update.(closed, :close)
    assert {:error, %{errors: [%Mana.Error{code: "demo.taken"}]}} = update.(ticket, :reopen)
    assert {:ok, %{status: :open}} = update.(closed, :reopen)

    owner = %{id: ticket.owner_id}
    assert {:error, %{errors: [%Mana.Error{code: "verb.unavailable"}]}} = Ash.update(ticket, %{}, action: :claim, actor: %{id: Ash.UUID.generate()}, authorize?: false)
    assert {:ok, _} = Ash.update(ticket, %{}, action: :claim, actor: owner, authorize?: false)
  end

  test "a failed step undoes the done ones through their inverses" do
    owner = %{id: Ash.UUID.generate()}
    task = fn -> Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Ship"}, actor: owner) end
    a = task.()
    b = task.()

    assert {:ok, [%{status: :done}, %{status: :done}]} = Mana.Verbs.run_all([{a, :finish, %{}}, {b, :finish, %{}}], owner)

    c = task.()
    d = task.()

    assert {:error, %{failed: 2, compensated: [%{id: undone, status: :open}], uncompensated: [%{id: archived}]}} =
             Mana.Verbs.run_all([{c, :finish, %{}}, {d, :archive, %{}}, {d, :explode, %{}}], owner)

    assert {undone, archived} == {c.id, d.id}
    assert Ash.get!(ManaCoreTest.Task, c.id, actor: owner).status == :open
    assert_raise ArgumentError, fn -> Mana.Verbs.run_all([{c, :missing, %{}}], owner) end
  end

  test "verb metadata reaches the contract" do
    assert [
             %{
               "name" => "close",
               "action" => "close",
               "risk" => "none",
               "idempotent" => false,
               "inverse" => "reopen",
               "feature" => "support/tickets",
               "archetypes" => ["authorization", "lifecycle-gate"]
             },
             %{"name" => "reopen"},
             %{"name" => "escalate", "risk" => "money", "idempotent" => true, "retry" => 2, "offline" => "reject", "archetypes" => ["authorization"]},
             %{"name" => "claim", "archetypes" => ["authorization", "lifecycle-gate"]}
           ] = Mana.Verbs.contract(ManaCoreTest.Ticket)
  end

  test "a verb must name an action and an inverse that exist" do
    resource = fn verbs ->
      """
      defmodule ManaCoreTest.V#{System.unique_integer([:positive])} do
        use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Verbs], validate_domain_inclusion?: false
        attributes do
          uuid_primary_key :id
        end
        actions do
          defaults [:read]
          update :close
        end
        verbs do
      #{verbs}
        end
      end
      """
    end

    assert :ok = compile(resource.("verb :close"))
    assert {:error, message} = compile(resource.("verb :missing"))
    assert message =~ "has no action"
    assert {:error, message} = compile(resource.("verb :close, inverse: :open"))
    assert message =~ "not a declared verb"
  end

  test "every change is announced on the record's topic and its audience's, with only the id" do
    Application.put_env(:mana_core, :test_pid, self())
    Application.put_env(:mana_core, :deadline_inserter, fn job -> send(self(), {:scheduled, job}) end)
    on_exit(fn -> Application.delete_env(:mana_core, :deadline_inserter) end)
    buyer = Ash.UUID.generate()

    order = ManaCoreTest.Order |> Ash.Changeset.for_create(:create, %{buyer_id: buyer}) |> Ash.create!()
    assert_received {:broadcast, topic, "changed", %{"id" => id, "type" => "order"}}
    assert topic == "entity:order:#{order.id}" and id == order.id
    assert_received {:broadcast, "entity:order:for:" <> ^buyer, "changed", _}
    assert_received {:broadcast, "entity:order:all", "changed", _}
    assert Mana.Entity.topics(order) == ["entity:order:#{order.id}", "entity:order:for:#{buyer}", "entity:order:all"]

    assert_received {:scheduled, %{args: %{"deadline" => "unpaid", "id" => ^id}, queue: :default, scheduled_at: at}}
    assert DateTime.diff(at, DateTime.utc_now(), :minute) in 29..30

    paid = order |> Ash.Changeset.for_update(:pay) |> Ash.update!()
    refute_received {:scheduled, _}
    assert :ok = Mana.Entity.run_deadline(ManaCoreTest.Order, paid.id, "unpaid")
    assert Ash.get!(ManaCoreTest.Order, paid.id).status == :paid
  end

  test "a deadline still satisfied performs its action; an unknown one does nothing" do
    Application.put_env(:mana_core, :test_pid, self())
    Application.put_env(:mana_core, :deadline_inserter, fn _ -> :ok end)
    on_exit(fn -> Application.delete_env(:mana_core, :deadline_inserter) end)
    order = ManaCoreTest.Order |> Ash.Changeset.for_create(:create, %{}) |> Ash.create!()

    assert :ok = Mana.Entity.run_deadline(ManaCoreTest.Order, order.id, "unpaid")
    assert Ash.get!(ManaCoreTest.Order, order.id).status == :expired
    assert :ok = Mana.Entity.run_deadline(ManaCoreTest.Order, order.id, "missing")
    assert :ok = Mana.Entity.run_deadline(ManaCoreTest.Order, Ash.UUID.generate(), "unpaid")
  end

  test "a view lists the fields a screen reads and the loads its read needs" do
    assert Mana.Views.loads(ManaCoreTest.Ticket, :row) == [:verbs]
    assert [%{"name" => "row", "fields" => ["status", "verbs", "owner_id"], "live" => true, "describe" => "a ticket in the queue"}] =
             Mana.Views.contract(ManaCoreTest.Ticket)

    assert_raise ArgumentError, fn -> Mana.Views.loads(ManaCoreTest.Ticket, :missing) end
  end

  test "a read serving a view loads what the view reads" do
    owner = Ash.UUID.generate()
    ticket = ManaCoreTest.Ticket |> Ash.Changeset.for_create(:create, %{owner_id: owner}) |> Ash.create!(authorize?: false)
    mine = &Enum.find(&1, fn read -> read.id == ticket.id end)

    assert %{verbs: verbs} = ManaCoreTest.Ticket |> Ash.Query.for_read(:queue) |> Ash.read!(actor: %{id: owner}) |> mine.()
    assert is_list(verbs)
    assert %{verbs: %Ash.NotLoaded{}} = ManaCoreTest.Ticket |> Ash.read!(actor: %{id: owner}) |> mine.()
  end

  test "a view may only read public fields" do
    resource = fn fields ->
      """
      defmodule ManaCoreTest.W#{System.unique_integer([:positive])} do
        use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets, extensions: [Mana.Views], validate_domain_inclusion?: false
        attributes do
          uuid_primary_key :id
          attribute :title, :string, public?: true
          attribute :secret, :string
        end
        actions do
          defaults [:read]
        end
        views do
          view :card, fields: #{fields}
        end
      end
      """
    end

    assert :ok = compile(resource.("[:id, :title]"))
    assert {:error, message} = compile(resource.("[:title, :secret]"))
    assert message =~ "not public: [:secret]"
  end

  describe "attachments" do
    setup do
      root = Path.join(System.tmp_dir!(), "mana-attach-#{System.unique_integer([:positive])}")
      Application.put_env(:mana_core, Mana.Storage, adapter: Mana.Storage.Local, root: root, base_url: "http://local/__storage", secret: "test-secret")
      :ok
    end

    test "the contract says what each attribute takes, from the files resource's kinds" do
      assert Mana.Attachments.contract(ManaCoreTest.Listing) == [
               %{"attribute" => "cover_id", "many" => false, "kinds" => [%{"name" => "photo", "accept" => Mana.Uploads.images(), "max_bytes" => 1_000}]},
               %{"attribute" => "gallery_ids", "many" => true, "kinds" => [%{"name" => "paper", "accept" => ["application/pdf"], "max_bytes" => 25_000_000}]}
             ]
    end

    test "only the actor's own ready files of the declared kinds attach, and the reads find them" do
      owner = %{id: Ash.UUID.generate()}
      photo = Mana.Attachments.fake(ManaCoreTest.Listing, :cover_id, owner.id)
      paper = Mana.Attachments.fake(ManaCoreTest.Listing, :gallery_ids, owner.id)
      assert {photo.status, photo.content_type, paper.content_type} == {:ready, "image/png", "application/pdf"}

      listing = Ash.create!(ManaCoreTest.Listing, %{cover_id: photo.id, gallery_ids: [paper.id]}, actor: owner)
      assert %{cover_url: "http://local/__storage/" <> _, files: [%{asset_id: id}, _]} = Ash.load!(listing, [:cover_url, :files])
      assert id == photo.id

      assert {:error, error} = Ash.update(listing, %{cover_id: paper.id}, actor: owner)
      assert inspect(error) =~ "upload.not_attachable"
      stranger = Mana.Attachments.fake(ManaCoreTest.Listing, :cover_id, Ash.UUID.generate())
      assert {:error, _} = Ash.update(listing, %{cover_id: stranger.id}, actor: owner)
      assert {:ok, _} = Ash.update(listing, %{}, action: :touch, actor: owner)
    end

    test "primitives place their contracts on the schema and list themselves in info" do
      spec = %{"info" => %{"title" => "t"}, "components" => %{"schemas" => %{"listing" => %{"type" => "object"}}}}
      placed = Mana.Primitive.put_contracts(spec, [ManaCoreTest.Domain])

      assert [%{"attribute" => "cover_id"}, _] = placed["components"]["schemas"]["listing"]["x-mana-attachments"]
      assert placed["info"]["x-mana-primitives"] == [%{"contract" => "x-mana-attachments", "catalog" => "uploads", "moments" => ["fake"]}]
      assert Mana.Primitive.of(ManaCoreTest.Ticket) == [Mana.Verbs, Mana.Views]
      assert_raise ArgumentError, fn -> Mana.Attachments.fake(ManaCoreTest.Ticket, :status, Ash.UUID.generate()) end
    end
  end

  describe "history" do
    test "each change is recorded with its author, inputs, before and after, and failures too" do
      owner = %{id: Ash.UUID.generate()}
      task = Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Ship", secret: "s1"}, actor: owner)
      task = task |> Ash.Changeset.for_update(:finish, %{note: "done!", secret: "s2"}, actor: owner) |> Ash.update!()
      assert {:error, _} = task |> Ash.Changeset.for_update(:finish, %{}, actor: owner) |> Ash.update()
      Ash.update!(task, %{}, action: :touch, actor: owner)
      task |> Ash.Changeset.for_update(:finish, %{}, context: %{mana_agent: "planner"}) |> Ash.update()

      entries = Mana.History.of(ManaCoreTest.HistoryEntry, "task", task.id, owner)
      assert [agent, failed, finished, created] = entries

      assert %{action: "create", actor_kind: :user, actor_id: actor_id, summary: "create", outcome: :done} = created
      assert actor_id == owner.id
      assert created.after["title"] == "Ship" and created.after["secret"] == "[redacted]"

      assert %{verb: "finish", summary: "finished the task", outcome: :done} = finished
      assert finished.params == %{"note" => "done!", "secret" => "[redacted]"}
      assert finished.before == %{"secret" => "[redacted]", "status" => "open"}
      assert finished.after == %{"secret" => "[redacted]", "status" => "done"}

      assert %{outcome: :failed, error: error, after: after_failure} = failed
      assert is_binary(error) and after_failure == %{}
      assert %{actor_kind: :agent, via: "planner", outcome: :failed} = agent

      assert Mana.History.of(ManaCoreTest.HistoryEntry, "task", task.id, nil) == []
      assert Mana.History.of(ManaCoreTest.HistoryEntry, "nothing", task.id, owner) == []
    end

    test "a record's history replays into a new record that ends where it ended" do
      owner = %{id: Ash.UUID.generate()}
      task = Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Ship", secret: "s"}, actor: owner)
      task |> Ash.Changeset.for_update(:finish, %{note: "ok"}, actor: owner) |> Ash.update!()
      task |> Ash.Changeset.for_update(:finish, %{}, actor: owner) |> Ash.update()

      entries = Mana.History.export(ManaCoreTest.HistoryEntry, "task", task.id)
      assert [%{"action" => "create", "outcome" => "done"}, %{"action" => "finish"}, %{"outcome" => "failed"}] = entries

      assert {:error, %{at: 0, action: :create, error: :redacted_input}} = Mana.History.replay(ManaCoreTest.Task, entries, actor: fn _ -> owner end)

      fill = fn
        :create, params -> Map.put(params, "secret", "replayed")
        _, params -> params
      end

      assert {:ok, copy, [:create, :finish]} = Mana.History.replay(ManaCoreTest.Task, entries, actor: fn _ -> owner end, params: fill)

      fixture = Mana.History.fixture(ManaCoreTest.HistoryEntry, "task", task.id, %{owner.id => "owner"})
      assert Enum.map(fixture, &{&1["action"], &1["actor_id"]}) == [{"create", "owner"}, {"finish", "owner"}]
      refute Enum.any?(fixture, &Map.has_key?(&1, "at"))
      assert {:ok, _, [:create, :finish]} = Mana.History.replay(ManaCoreTest.Task, fixture, actor: %{"owner" => owner}, params: fill)
      assert copy.id != task.id
      assert {copy.status, copy.title, copy.secret} == {:done, "Ship", "replayed"}
    end

    test "a checkpoint keeps a plan only with a green verdict, and refuses what it cannot roll back" do
      owner = %{id: Ash.UUID.generate()}
      task = Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Ship"}, actor: owner)
      plan = [%{"resource" => "ManaCoreTest.Task", "id" => task.id, "verb" => "finish", "params" => %{}}]

      assert {:error, :cannot_roll_back} = Mana.Checkpoint.dry_run(plan, owner)
      assert {:error, :verdict_not_green} = Mana.Checkpoint.keep(plan, owner, %{"outcome" => "fail"})
      assert {:ok, %{status: :done, records: [%{id: id}]}} = Mana.Checkpoint.keep(plan, owner, %{"outcome" => "pass"})
      assert id == task.id
      assert Ash.get!(ManaCoreTest.Task, task.id, actor: owner).status == :done

      escalate = [%{"resource" => "ManaCoreTest.Ticket", "id" => Ash.Seed.seed!(ManaCoreTest.Ticket, %{owner_id: owner.id}).id, "verb" => "escalate"}]
      assert {:error, %{irreversible: [%{verb: :escalate}]}} = Mana.Checkpoint.dry_run(escalate, owner)
    end

    test "a verb that reaches an outside system is refused by checkpoints and replays" do
      person = %{id: Ash.UUID.generate()}
      diary = Ash.create!(ManaCoreTest.Diary, %{person_id: person.id, body: "hi"}, actor: person)
      diary |> Ash.Changeset.for_update(:mail, %{}, actor: person) |> Ash.update!()

      plan = [%{"resource" => "ManaCoreTest.Diary", "id" => diary.id, "verb" => "mail"}]
      assert {:error, %{irreversible: [%{verb: :mail}]}} = Mana.Checkpoint.dry_run(plan, person)
      assert [%{"external" => "email", "name" => "mail"}] = Mana.Verbs.contract(ManaCoreTest.Diary)

      entries = Mana.History.export(ManaCoreTest.HistoryEntry, "diary", diary.id)
      assert {:error, %{at: 1, action: :mail, error: :external}} = Mana.History.replay(ManaCoreTest.Diary, entries, actor: fn _ -> person end)
      assert {:ok, _, [:create]} = Mana.History.replay(ManaCoreTest.Diary, entries, actor: fn _ -> person end, external: :skip)
    end

    test "an agent opens an entry and follows only the verbs a record offers" do
      owner = %{id: Ash.UUID.generate()}
      task = Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Agent task"}, actor: owner)
      domains = [ManaCoreTest.Domain]

      assert %{name: "task.card"} = Enum.find(Mana.Agent.entries(domains), &(&1.name == "task.card"))
      assert {:error, %{reason: "no_such_entry"}} = Mana.Agent.open(domains, "task.nothing", owner)

      {:ok, %{records: records}} = Mana.Agent.open(domains, "task.card", owner)
      card = Enum.find(records, &(&1.id == task.id))
      assert card.fields == %{"title" => "Agent task", "status" => "open"}
      assert "finish" in Enum.map(card.verbs, & &1["name"])
      assert %{"inputs" => [%{"name" => "secret"}, %{"name" => "note"}]} = Enum.find(card.verbs, &(&1["name"] == "finish"))

      assert {:error, %{reason: "not_offered", offered: offered}} = Mana.Agent.follow(domains, "task", task.id, "reopen", %{}, owner)
      refute "reopen" in offered
      assert {:ok, %{fields: %{"status" => "done"}, verbs: after_verbs}} = Mana.Agent.follow(domains, "task", task.id, "finish", %{"note" => "by agent"}, owner, agent: "planner")
      assert "reopen" in Enum.map(after_verbs, & &1["name"])
      assert [%{actor_kind: :agent, via: "planner"} | _] = Mana.History.of(ManaCoreTest.HistoryEntry, "task", task.id, owner)
      assert {:error, %{reason: "not_found"}} = Mana.Agent.follow(domains, "task", Ash.UUID.generate(), "finish", %{}, owner)
      assert {:error, %{reason: "no_such_type"}} = Mana.Agent.follow(domains, "ghost", task.id, "finish", %{}, owner)
    end

    test "why a value shows: the entries that set it, with the verb, the author and the step" do
      owner = %{id: Ash.UUID.generate()}
      task = Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Why task"}, actor: owner)
      task |> Ash.Changeset.for_update(:finish, %{}, actor: owner, context: %{mana_agent: "planner"}) |> Ash.update!()

      assert [%{record: record, field: "status", before: "open", after: "done", set_by: "finish", actor: %{kind: :agent, via: "planner"}, moment: nil} | _] =
               ManaCoreTest.HistoryEntry |> Mana.Why.explain("done") |> Enum.filter(&(&1.record == "task:#{task.id}"))

      assert record == "task:#{task.id}"
      assert [%{field: "title", set_by: "create"}] = Mana.Why.explain(ManaCoreTest.HistoryEntry, "Why task")
      assert Mana.Why.explain(ManaCoreTest.HistoryEntry, "nothing like this") == []

      root = Path.join(System.tmp_dir!(), "mana-why-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      report = Path.join(root, "apps/shop/moments/.proofs/r.json")
      File.mkdir_p!(Path.dirname(report))
      File.write!(report, Jason.encode!(%{"steps" => [%{"id" => "g-1", "name" => "cancel"}]}))
      summary = Path.join(root, "apps/shop/moments/.suite/run-1/summary.json")
      File.mkdir_p!(Path.dirname(summary))
      File.write!(summary, Jason.encode!(%{"results" => [%{"name" => "shop-cancel", "report" => report}]}))
      assert Mana.Why.gesture_steps(root) == %{"g-1" => "shop:shop-cancel step cancel"}
    end

    test "the contract names the log and what is redacted" do
      assert [%{"subject" => "task", "redacted" => ["secret"], "log" => nil}] = Mana.History.contract(ManaCoreTest.Task)
    end
  end

  describe "flows" do
    setup do
      test_pid = self()
      Application.put_env(:mana_core, :test_pid, test_pid)
      Application.put_env(:mana_core, :deadline_inserter, &send(test_pid, {:scheduled, &1}))
      on_exit(fn -> Application.delete_env(:mana_core, :deadline_inserter) end)
    end

    defp go(record, action, params \\ %{}), do: Ash.update(record, params, action: action)

    test "steps advance in order, refuse what is not reached, skip what does not apply, never move back" do
      signup = Ash.create!(ManaCoreTest.Signup, %{})
      assert {:error, error} = go(signup, :save_details)
      assert inspect(error) =~ "flow.step_not_reached"

      {:ok, signup} = go(signup, :accept_terms)
      assert signup.stage == :details
      assert_received {:scheduled, %{args: %{"step" => "details", "kind" => "flow_stuck"}}}

      {:ok, signup} = go(signup, :accept_terms)
      assert signup.stage == :details

      {:ok, signup} = go(signup, :save_details, %{kind: :virtual})
      assert signup.stage == :done
      assert %{flow: %{step: "done", index: 3, total: 3, progress: 1.0, done: true}} = Ash.load!(signup, :flow)

      demo = Ash.create!(ManaCoreTest.Signup, %{stage: :demo})
      assert {:error, _} = go(demo, :accept_terms)
      assert %{flow: %{index: 0, progress: +0.0, done: false}} = Ash.load!(demo, :flow)
    end

    test "a step left too long calls on_stuck; one that moved does not" do
      signup = Ash.create!(ManaCoreTest.Signup, %{})
      {:ok, signup} = go(signup, :accept_terms)

      assert Mana.Flow.check_stuck(ManaCoreTest.Signup, signup.id, "details") == :abandoned
      assert_received {:stuck, id, :details}
      assert id == signup.id
      assert Mana.Flow.check_stuck(ManaCoreTest.Signup, signup.id, "terms") == :moved

      record = fn error ->
        ManaCoreTest.HistoryEntry
        |> Ash.Changeset.for_create(:record, %{subject_type: "signup", subject_id: signup.id, action: "save_details", actor_kind: :user, outcome: :failed, error: error, summary: "save details"})
        |> Ash.create!()
      end

      record.("invalid")
      assert %{verdict: :abandoned, attempts: 1, failures: ["invalid"]} = Mana.Flow.diagnose(signup, :details)
      record.("unknown")
      assert Mana.Flow.check_stuck(ManaCoreTest.Signup, signup.id, "details") == :bug
      assert %{verdict: :bug, attempts: 2} = Mana.Flow.diagnose(signup, :details)
    end

    test "the funnel counts each step and the contract lists them" do
      assert [terms: _, details: _, address: _, done: _] = Mana.Flow.funnel(ManaCoreTest.Signup)

      assert [%{"cursor" => "stage", "done" => "done", "steps" => [%{"name" => "terms", "action" => "accept_terms"}, _, %{"name" => "address", "skippable" => true}]}] =
               Mana.Flow.contract(ManaCoreTest.Signup)
    end
  end

  describe "notifications" do
    setup do
      Application.put_env(:mana_core, :test_pid, self())
      Application.put_env(:mana_core, :deadline_inserter, fn _ -> :ok end)
      on_exit(fn -> Application.delete_env(:mana_core, :deadline_inserter) end)
    end

    test "a successful action sends what it declares to whom it names; the actor never notifies itself" do
      buyer = Ash.UUID.generate()
      order = Ash.create!(ManaCoreTest.Order, %{buyer_id: buyer})
      refute_received {:notice, _}

      Ash.update!(order, %{}, action: :pay)
      assert_received {:notice, %{to: ^buyer, template: "order.paid", category: :orders, channels: [:inbox, :email], opens: opens, payload: payload}}
      assert opens == "/orders/#{order.id}" and payload == %{"order_id" => order.id, "status" => "paid", "buyer_id" => buyer}

      Ash.update!(order, %{}, action: :pay, actor: %{id: buyer})
      refute_received {:notice, _}

      Ash.update!(order, %{}, action: :expire)
      assert_received {:notice, %{to: ^buyer, template: "order.expired"}}
      Ash.update!(Ash.create!(ManaCoreTest.Order, %{}), %{}, action: :expire)
      refute_received {:notice, _}
    end

    test "delivery follows the person: muted channels, quiet hours and fallback" do
      buyer = Ash.UUID.generate()
      order = Ash.create!(ManaCoreTest.Order, %{buyer_id: buyer})

      Application.put_env(:mana_core, :muted, [:email])
      on_exit(fn -> Application.delete_env(:mana_core, :muted) end)
      Ash.update!(order, %{}, action: :pay)
      assert_received {:notice, %{template: "order.paid", channels: [:inbox]}}

      Application.put_env(:mana_core, :muted, [])
      held = Mana.Notifications.deliver(ManaCoreTest.Order, %{to: buyer, template: "order.paid", category: :orders, channels: [:inbox, :email], opens: nil, payload: %{}, record: order})
      assert held == [:inbox, :email]

      until = DateTime.add(DateTime.utc_now(), 8, :hour)
      Application.put_env(:mana_core, :quiet_until, until)
      Application.put_env(:mana_core, :deadline_inserter, &send(self(), {:held, &1}))
      on_exit(fn -> Application.delete_env(:mana_core, :quiet_until) end)
      assert [:inbox] = Mana.Notifications.deliver(ManaCoreTest.Order, %{to: buyer, template: "order.paid", category: :orders, channels: [:inbox, :email], opens: nil, payload: %{}, record: order})
      assert_received {:held, %{scheduled_at: ^until, args: %{"notice" => %{"channels" => [:email]} = notice}}}
      assert [:email] = Mana.Notifications.deliver_held(ManaCoreTest.Order, Jason.decode!(Jason.encode!(notice)))
      Application.delete_env(:mana_core, :quiet_until)

      Ash.update!(order, %{buyer_id: buyer}, action: :adopt)
      assert_received {:notice, %{template: "order.adopted", channels: [:inbox]}}
      assert_received {:notice, %{template: "order.adopted", channels: [:push]}}
      assert_received {:notice, %{template: "order.adopted", channels: [:email]}}
      refute_received {:notice, %{template: "order.adopted", channels: [:sms]}}
    end

    test "repeats about the same record inside the grouping window reach the inbox only, counted" do
      user = Ash.UUID.generate()
      alert = Ash.create!(ManaCoreTest.Alert, %{user_id: user})
      assert_received {:notice, %{template: "alert.raised", channels: [:inbox, :email]} = first}
      refute Map.has_key?(first, :group)

      again = %{first | channels: [:inbox, :email]} |> Map.put(:record, alert)
      assert [:inbox] = Mana.Notifications.deliver(ManaCoreTest.Alert, again)
      assert [:inbox] = Mana.Notifications.deliver(ManaCoreTest.Alert, again)
      assert_received {:notice, %{channels: [:inbox], group: %{count: 2}}}
      assert_received {:notice, %{channels: [:inbox], group: %{count: 3}}}

      Ash.create!(ManaCoreTest.Alert, %{user_id: user})
      assert_received {:notice, %{template: "alert.raised", channels: [:inbox, :email]}}
    end

    test "the contract tells clients each notice's category, channels and link" do
      assert [
               %{"action" => "pay", "template" => "order.paid", "category" => "orders", "channels" => ["inbox", "email"], "opens" => "/orders/:id"},
               %{"action" => "adopt"},
               %{"action" => "expire", "category" => "general"} = expire
             ] = Mana.Notifications.contract(ManaCoreTest.Order)

      refute Map.has_key?(expire, "opens")
    end
  end

  describe "knobs" do
    test "a knob answers its default until set, then the stored value, and rejects the wrong type" do
      ManaCoreTest.Knobs.unset(:pinning)
      ManaCoreTest.Knobs.unset(:page_size)
      assert ManaCoreTest.Knobs.get(:page_size) == 20
      assert {:error, _} = ManaCoreTest.Knobs.set(:page_size, "many", nil)
      assert {:ok, _} = ManaCoreTest.Knobs.set(:page_size, 50, %{id: Ash.UUID.generate()})
      assert ManaCoreTest.Knobs.get(:page_size) == 50
      assert_raise ArgumentError, fn -> ManaCoreTest.Knobs.get(:missing) end
      assert [%{name: :pinning, feature: "tasks"}, %{name: :page_size, value: 50}] = ManaCoreTest.Knobs.knobs()
      assert :pinning in ManaCoreTest.Knobs.stale()
      refute :page_size in ManaCoreTest.Knobs.stale()
      assert :ok = ManaCoreTest.Knobs.unset(:page_size)
      assert ManaCoreTest.Knobs.get(:page_size) == 20
    end

    test "a verb behind a knob is offered and allowed only while it is on for the actor" do
      owner = %{id: Ash.UUID.generate()}
      task = Ash.create!(ManaCoreTest.Task, %{owner_id: owner.id, title: "Pin me"}, actor: owner)
      refute "pin" in Mana.Verbs.offered(task, owner)
      assert {:error, error} = Ash.update(task, %{}, action: :pin, actor: owner)
      assert inspect(error) =~ "feature.disabled"

      Application.put_env(:mana_core, :pinning_default, true)
      on_exit(fn -> Application.delete_env(:mana_core, :pinning_default) end)
      assert "pin" in Mana.Verbs.offered(task, owner)

      ManaCoreTest.Knobs.set(:pinning, %{"value" => false, "actors" => [owner.id]}, nil)
      assert "pin" in Mana.Verbs.offered(task, owner)
      assert {:ok, _} = Ash.update(task, %{}, action: :pin, actor: owner)
      refute ManaCoreTest.Knobs.enabled?(:pinning, %{id: Ash.UUID.generate()})

      ManaCoreTest.Knobs.set(:pinning, %{"value" => false, "percent" => 100}, nil)
      assert ManaCoreTest.Knobs.enabled?(:pinning, %{id: Ash.UUID.generate()})
      refute ManaCoreTest.Knobs.enabled?(:pinning)
    end
  end

  describe "reconciliation" do
    test "a rule observes its scope, reports what diverges, repairs only when asked and gives a verdict" do
      Application.put_env(:mana_core, :deadline_inserter, fn _ -> :ok end)
      Application.put_env(:mana_core, :test_pid, self())
      on_exit(fn -> Application.delete_env(:mana_core, :deadline_inserter) end)

      for order <- Ash.read!(ManaCoreTest.Order), do: Ash.destroy!(order)
      Ash.create!(ManaCoreTest.Order, %{buyer_id: Ash.UUID.generate(), status: :paid})
      orphan = Ash.create!(ManaCoreTest.Order, %{status: :paid})
      Ash.create!(ManaCoreTest.Order, %{status: :open})

      assert [%{rule: :paid_has_buyer, state: :diverging, checked: 2, diverging: [%{id: id, detail: "paid without a buyer"}]} = report] =
               Mana.Reconcile.observe(ManaCoreTest.Order)

      assert id == orphan.id
      assert %{"outcome" => "fail", "acceptanceScore" => +0.0, "criteria" => [%{"status" => "fail", "evidence" => [%{"id" => ^id}]}]} =
               Mana.Reconcile.verdict("orders", [report])

      Application.put_env(:mana_core, :adopter, nil)
      assert [%{state: :blocked, repaired: 0}] = Mana.Reconcile.observe(ManaCoreTest.Order, apply: true)

      Application.put_env(:mana_core, :adopter, Ash.UUID.generate())
      on_exit(fn -> Application.delete_env(:mana_core, :adopter) end)
      assert [%{state: :converged, repaired: 1} = done] = Mana.Reconcile.observe(ManaCoreTest.Order, apply: true)
      assert %{"outcome" => "pass", "acceptanceScore" => 1.0} = Mana.Reconcile.verdict("orders", [done])
    end
  end

  describe "server interventions" do
    test "fn: makes a marked function raise or answer a value; latency: delays matching paths; nothing without the switch" do
      on_exit(fn ->
        Mana.Intervene.Rules.set([])
        Application.delete_env(:mana_core, :interventions)
      end)

      Mana.Intervene.Rules.set(["fn:ManaCoreTest.Pricing.total=7", "latency:/api/slow/**=25", "nonsense"])
      assert ManaCoreTest.Pricing.total([1], %{rate: 3}) == 3
      assert Mana.Intervene.Rules.latency("/api/slow/a") == 0

      Application.put_env(:mana_core, :interventions, true)
      assert ManaCoreTest.Pricing.total([1], %{rate: 3}) == 7
      assert Mana.Intervene.Rules.latency("/api/slow/a/b") == 25
      assert Mana.Intervene.Rules.latency("/api/fast") == 0

      Mana.Intervene.Rules.set(["fn:ManaCoreTest.Pricing.total=raise"])
      assert_raise RuntimeError, ~r/intervention/, fn -> ManaCoreTest.Pricing.total([1], %{rate: 3}) end
      Mana.Intervene.Rules.set(["fn:ManaCoreTest.Pricing.total=nil"])
      assert ManaCoreTest.Pricing.total([1], %{rate: 3}) == nil
      Mana.Intervene.Rules.set(["fn:ManaCoreTest.Pricing.total=not json"])
      assert ManaCoreTest.Pricing.total([1], %{rate: 3}) == "not json"

      Mana.Intervene.Rules.set(["latency:/x=5"])
      conn = Plug.Test.conn(:get, "/x")
      started = System.monotonic_time(:millisecond)
      assert Mana.Intervene.Plug.call(conn, []) == conn
      assert System.monotonic_time(:millisecond) - started >= 5
    end
  end

  describe "live examples" do
    test "a marked function behaves as def and records only when configured, inside a traced request" do
      dir = Path.join(System.tmp_dir!(), "mana-examples-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      assert ManaCoreTest.Pricing.total([1, 2], %{rate: 10}) == 30
      refute File.exists?(dir)

      Application.put_env(:mana_core, :examples, dir: dir)
      on_exit(fn -> Application.delete_env(:mana_core, :examples) end)
      assert ManaCoreTest.Pricing.total([1], %{rate: 2}) == 2
      refute File.exists?(dir)
      assert :ok = Mana.Examples.record(ManaCoreTest.Pricing, :total, 2, [[1], %{rate: 2}], 2)

      task = Ash.create!(ManaCoreTest.Task, %{owner_id: Ash.UUID.generate(), title: "Ship"}, authorize?: false)
      shown = Mana.Examples.describe([task])
      assert shown =~ ~s({"Task", %{) and shown =~ ~s(title: "Ship") and not (shown =~ "__meta__")
    end
  end

  test "a notice's recipients and payload can come from a function of the record" do
    mention = Ash.Seed.seed!(ManaCoreTest.Mention, %{names: ["ana", "bia"]})
    notices = Mana.Notifications.notices(mention, :create, nil)
    assert Enum.map(notices, & &1.to) == ["user-ana", "user-bia"]
    assert Enum.all?(notices, &(&1.payload == %{"count" => 2, "mention_id" => mention.id}))
  end

  test "a collection verb is offered by its parent or to the person, and refused on the server otherwise" do
    owner = %{id: Ash.UUID.generate(), role: :user}
    agent = %{id: Ash.UUID.generate(), role: :agent}
    open = Ash.Seed.seed!(ManaCoreTest.Ticket, %{owner_id: owner.id, status: :open})
    closed = Ash.Seed.seed!(ManaCoreTest.Ticket, %{owner_id: owner.id, status: :closed})

    assert "reply.post" in Mana.Verbs.offered(open, owner)
    refute "reply.post" in Mana.Verbs.offered(closed, owner)

    post = &Ash.create(ManaCoreTest.Reply, %{ticket_id: &1.id, body: "Oi"}, action: :post, actor: owner, authorize?: false)
    assert {:ok, _} = post.(open)
    assert {:error, %{errors: [%Mana.Error{code: "verb.unavailable"}]}} = post.(closed)

    assert "reply.announce" in Mana.Verbs.available([ManaCoreTest.Domain], agent)
    refute "reply.announce" in Mana.Verbs.available([ManaCoreTest.Domain], owner)
    assert :ok = Mana.Verbs.allowed(ManaCoreTest.Reply, :announce, agent)
    digest = &(ManaCoreTest.Reply |> Ash.ActionInput.for_action(:digest, %{}, actor: &1) |> Ash.run_action(authorize?: false))
    assert {:ok, "digest"} = digest.(agent)
    assert {:error, %{errors: [%Mana.Error{code: "verb.unavailable"}]}} = digest.(owner)
    assert {:error, %Mana.Error{code: "verb.unavailable"}} = Mana.Verbs.allowed(ManaCoreTest.Reply, :announce, owner)

    assert {:ok, %{type: "reply", id: _}} = Mana.Agent.follow([ManaCoreTest.Domain], "ticket", open.id, "reply.post", %{"body" => "Pelo agente"}, owner, agent: "planner")
    assert {:error, %{reason: "not_offered"}} = Mana.Agent.follow([ManaCoreTest.Domain], "ticket", closed.id, "reply.post", %{"body" => "x"}, owner)

    assert %{"collection" => true, "from" => "ticket", "field" => "ticket_id", "archetypes" => ["authorization", "lifecycle-gate"]} =
             Enum.find(Mana.Verbs.contract(ManaCoreTest.Reply), &(&1["name"] == "post"))
  end

  test "a flow's steps are offered as verbs once the flow reached them" do
    signup = Ash.Seed.seed!(ManaCoreTest.Signup, %{stage: :terms})
    assert Mana.Verbs.offered(signup, nil) == ["accept_terms"]
    assert Mana.Verbs.offered(%{signup | stage: :address}, nil) == ["accept_terms", "save_details", "save_address"]
    assert Mana.Verbs.offered(%{signup | stage: :demo}, nil) == []
  end
end
