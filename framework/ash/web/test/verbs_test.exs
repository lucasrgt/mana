defmodule ManaWeb.VerbsTest do
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias ManaCoreTest.Ticket
  alias ManaWeb.Verbs

  setup do
    owner = %{id: Ash.UUID.generate()}
    ticket = Ash.Seed.seed!(Ticket, %{owner_id: owner.id, status: :open})
    %{owner: owner, ticket: Ash.load!(ticket, :verbs, actor: owner)}
  end

  defp gate(record, name) do
    assigns = %{record: record, name: name}

    rendered_to_string(~H"""
    <Verbs.gate :let={verb} record={@record} verb={@name}>
      <button data-risk={verb.risk} data-confirm={verb.confirm? && "sure?"}>go</button>
    </Verbs.gate>
    """)
  end

  test "a control appears only for what the record offers its actor", %{ticket: ticket} do
    assert Verbs.offered?(ticket, :close)
    assert Verbs.offered?(ticket, "claim")
    refute Verbs.offered?(ticket, :reopen)
    refute Verbs.offered?(ticket, :escalate)

    assert gate(ticket, :close) =~ "<button"
    refute gate(ticket, :reopen) =~ "<button"
  end

  test "a verb says how it presents itself; money is always confirmed" do
    assert %{risk: :none, confirm?: false, inverse: :reopen, feature: "support/tickets"} =
             Verbs.describe(Ticket, :close)

    assert %{risk: :money, confirm?: true, idempotent?: true} = Verbs.describe(Ticket, :escalate)
    assert_raise ArgumentError, fn -> Verbs.describe(Ticket, :fly) end
  end

  test "a record read without its verbs is a mistake, not an empty offer", %{owner: owner} do
    bare = Ash.Seed.seed!(Ticket, %{owner_id: owner.id, status: :open})
    assert_raise ArgumentError, ~r/load :verbs/, fn -> Verbs.offered?(bare, :close) end
  end

  test "running a verb goes through its action, and the server keeps refusing", %{
    owner: owner,
    ticket: ticket
  } do
    assert {:ok, %{status: :closed} = closed} = Verbs.run(ticket, :close, %{}, actor: owner)

    assert {:error, error} = Verbs.run(closed, :close, %{}, actor: owner)
    assert %{message: message} = Verbs.refusal(error)
    assert is_binary(message)

    stranger = %{id: Ash.UUID.generate()}
    assert {:error, %Ash.Error.Forbidden{}} = Verbs.run(closed, :reopen, %{}, actor: stranger)
  end

  test "a run is recorded under its verb's feature", %{owner: owner, ticket: ticket} do
    start_supervised!(Mana.Feature)
    {:ok, _closed} = Verbs.run(ticket, :close, %{}, actor: owner)

    assert [%{feature: "support/tickets", requests: 1, errors: 0}] = Mana.Feature.report(1)
  end
end
