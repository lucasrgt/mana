defmodule PostgresTest.Repo.Migrations.Stays do
  use Ecto.Migration

  def change do
    create table(:people, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text, null: false)
      add(:email, :text, null: false)
      add(:phone, :text)
      add(:role, :text, null: false)
      add(:verified, :boolean, null: false, default: false)
      add(:hashed_password, :text, null: false)
    end

    create table(:stays, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:host_id, references(:people, type: :uuid, on_delete: :restrict), null: false)
      add(:traveler_id, references(:people, type: :uuid, on_delete: :restrict), null: false)
      add(:accepted_by_id, references(:people, type: :uuid, on_delete: :restrict))
      add(:status, :text, null: false)
      add(:total_cents, :integer, null: false)
      add(:lines, {:array, :map}, null: false, default: [])
      add(:scheduled_for, :utc_datetime, null: false)
      add(:guest_note, :text)
      add(:paid, :boolean, null: false, default: false)
    end
  end
end
