defmodule PostgresTest.Repo.Migrations.Catalog do
  use Ecto.Migration

  def change do
    create table(:venues, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:status, :text, null: false)
      add(:inserted_at, :utc_datetime, null: false)
    end

    create table(:offerings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:venue_id, references(:venues, type: :uuid, on_delete: :restrict), null: false)
      add(:title, :text, null: false)
      add(:status, :text, null: false)
    end
  end
end
