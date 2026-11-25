defmodule Mana.VerbsTenantPostgresTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  alias PostgresTest.{Harness, Repo, VerbsDomain, VerbsTenantBook, VerbsTenantShelf}

  setup_all do
    Harness.start!()
    VerbsDomain.create_tables!(Repo)
    :ok
  end

  setup do
    Harness.reset!()
    VerbsDomain.truncate!(Repo)
  end

  defp shelf(org, status \\ :open),
    do: Ash.create!(VerbsTenantShelf, %{status: status}, tenant: org)

  test "a verb on an attribute-multitenant record is checked again inside its tenant" do
    org = Ash.UUID.generate()
    open = shelf(org)

    assert {:ok, %{status: :closed} = closed} = Ash.update(open, %{}, action: :close, tenant: org)
    assert {:error, _} = Ash.update(closed, %{}, action: :close, tenant: org)
  end

  test "the verbs a read loads ask the stored row inside the record's tenant" do
    org = Ash.UUID.generate()
    one = shelf(org)
    for _ <- 1..2, do: Ash.create!(VerbsTenantBook, %{shelf_id: one.id}, tenant: org)

    [loaded] = VerbsTenantShelf |> Ash.Query.load(:verbs) |> Ash.read!(tenant: org)
    assert "tidy" in loaded.verbs
  end

  test "a collection verb reads its parent inside the tenant of the create" do
    org = Ash.UUID.generate()
    open = shelf(org)
    closed = shelf(org, :closed)

    assert {:ok, _} = Ash.create(VerbsTenantBook, %{shelf_id: open.id}, tenant: org)
    assert {:error, _} = Ash.create(VerbsTenantBook, %{shelf_id: closed.id}, tenant: org)
  end
end
