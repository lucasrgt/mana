defmodule PostgresTest.Repo.Migrations.Harness do
  use Ecto.Migration

  def up do
    Oban.Migration.up()

    create table(:orders, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:buyer_id, :uuid)
      add(:title, :text)
      add(:status, :text, null: false, default: "open")
    end

    create table(:history_entries, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:subject_type, :text, null: false)
      add(:subject_id, :text, null: false)
      add(:action, :text, null: false)
      add(:verb, :text)
      add(:actor_id, :uuid)
      add(:actor_kind, :text, null: false)
      add(:via, :text)
      add(:params, :map, null: false, default: %{})
      add(:before, :map, null: false, default: %{})
      add(:after, :map, null: false, default: %{})
      add(:outcome, :text, null: false)
      add(:error, :text)
      add(:summary, :text, null: false)
      add(:trace, :text)
      add(:report, :text)
      add(:at, :utc_datetime_usec, null: false)
    end

    # A log that refuses one entry, so a test can make writing it fail.
    create(
      constraint(:history_entries, :history_refuses_unrecordable,
        check: ~s|"after"->>'title' IS DISTINCT FROM 'unrecordable'|
      )
    )

    create table(:travelers, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:name, :text)
      add(:email, :text)
    end

    create table(:bookings, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:traveler_id, :uuid)
      add(:guest_name, :text)
      add(:phone, :text)
      add(:nights, :integer)
    end

    create table(:reviews, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:author_id, :uuid)
      add(:text, :text)
      add(:public, :boolean, null: false, default: true)
    end

    create table(:cards, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:title, :text)
      add(:status, :text, null: false, default: "draft")
      add(:archived, :boolean, null: false, default: false)
    end
  end

  def down do
    for table <- [:cards, :reviews, :bookings, :travelers, :history_entries, :orders],
        do: drop(table(table))

    Oban.Migration.down()
  end
end
