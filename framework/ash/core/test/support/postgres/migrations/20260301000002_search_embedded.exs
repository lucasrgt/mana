defmodule PostgresTest.Repo.Migrations.SearchEmbedded do
  use Ecto.Migration

  def change do
    alter table(:places) do
      add(:services, {:array, :map})
      add(:featured, :map)
    end
  end
end
