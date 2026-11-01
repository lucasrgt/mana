defmodule RecipesScopeTest.Repo.Migrations.CreateRows do
  use Ecto.Migration

  def change do
    create table(:rows, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:label, :text)
    end
  end
end
