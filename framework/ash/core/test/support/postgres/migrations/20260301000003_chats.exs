defmodule PostgresTest.Repo.Migrations.Chats do
  use Ecto.Migration

  def change do
    create table(:threads, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:topic, :text, null: false)
      add(:asks, :integer, null: false, default: 1)
    end

    create(unique_index(:threads, [:topic], name: "threads_topic_index"))

    create table(:notes, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:thread_id, references(:threads, type: :uuid, on_delete: :restrict), null: false)
      add(:body, :text)
    end

    create table(:ratings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:thread_id, references(:threads, type: :uuid, on_delete: :restrict), null: false)
      add(:stars, :integer)
    end

    create(unique_index(:ratings, [:thread_id], name: "ratings_thread_index"))
  end
end
