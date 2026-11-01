defmodule SnapshotTest.Repo.Migrations.CreateNotes do
  use Ecto.Migration

  def change do
    create table(:notes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:body, :text)
    end
  end
end
