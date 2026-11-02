defmodule PostgresTest.Repo.Migrations.Search do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS unaccent")

    create table(:places, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text)
      add(:city, :text)
      add(:tags, {:array, :text})
    end
  end

  def down do
    drop(table(:places))
    execute("DROP EXTENSION IF EXISTS unaccent")
  end
end
