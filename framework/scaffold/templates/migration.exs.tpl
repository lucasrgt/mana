defmodule {{Module}}.Repo.Migrations.Create{{Collection}} do
  use Ecto.Migration
  def change do
    create table(:{{name}}, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:owner_id, :text, null: false)
      add(:title, :text, null: false)
      add(:{{state}}, :boolean, null: false, default: false)
    end
    create(index(:{{name}}, [:owner_id, :id]))
  end
end
