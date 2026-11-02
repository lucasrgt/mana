defmodule PostgresTest.Repo.Migrations.Erasure do
  use Ecto.Migration

  def change do
    create table(:erasure_files, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:owner_id, :uuid, null: false)
      add(:kind, :text, null: false)
      add(:content_type, :text, null: false)
      add(:size_bytes, :integer, null: false)
      add(:storage_key, :text, null: false)
      add(:status, :text, null: false, default: "uploading")
      add(:thumbnail_key, :text)
      add(:created_at, :utc_datetime, null: false)
      add(:updated_at, :utc_datetime, null: false)
    end
  end
end
