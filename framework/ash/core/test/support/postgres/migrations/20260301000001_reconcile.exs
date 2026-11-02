defmodule PostgresTest.Repo.Migrations.Reconcile do
  use Ecto.Migration

  def change do
    create table(:ledgers, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:status, :text, null: false)
      add(:charge_id, :uuid)
      add(:refunded, :boolean)
    end
  end
end
