defmodule ErasureStorageTest.Files do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Mana.Uploads.Thumbnail
  alias PostgresTest.{ErasureFile, Repo}

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  def png, do: @png

  def local_storage! do
    root = Path.join(System.tmp_dir!(), "mana-erasure-#{System.unique_integer([:positive])}")
    previous = Application.get_env(:mana_core, Mana.Storage)

    Application.put_env(:mana_core, Mana.Storage,
      adapter: Mana.Storage.Local,
      root: root,
      base_url: "http://local/__storage",
      secret: "test-secret"
    )

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: Application.put_env(:mana_core, Mana.Storage, previous),
        else: Application.delete_env(:mana_core, Mana.Storage)
    end)

    Repo.query!("TRUNCATE erasure_files")
    :ok
  end

  @doc "A ready photo of `owner`, its object and thumbnail stored."
  def stored!(owner) do
    file = original!(owner)
    thumbnail = Thumbnail.key(file.storage_key)
    :ok = Mana.Storage.put(thumbnail, "thumb", "image/jpeg")
    Ash.update!(file, %{thumbnail_key: thumbnail}, action: :attach_thumbnail)
  end

  @doc "A ready photo of `owner` (a real PNG) whose thumbnail is not made yet."
  def original!(owner) do
    id = Ash.UUID.generate()
    key = "uploads/#{owner}/photo/#{id}"
    :ok = Mana.Storage.put(key, @png, "image/png")

    ErasureFile
    |> Ash.create!(
      %{
        id: id,
        owner_id: owner,
        kind: :photo,
        content_type: "image/png",
        size_bytes: byte_size(@png),
        storage_key: key
      },
      action: :register
    )
    |> Ash.update!(%{}, action: :mark_ready)
  end

  @doc "Which of the file's object and thumbnail are in storage."
  def objects(file),
    do:
      Enum.filter(
        [file.storage_key, Thumbnail.key(file.storage_key)],
        &Mana.Storage.exists?/1
      )

  def both(file), do: [file.storage_key, Thumbnail.key(file.storage_key)]

  def jobs,
    do:
      "SELECT state FROM oban_jobs WHERE worker = 'Mana.Uploads.Discard.Worker' ORDER BY id"
      |> Repo.query!()
      |> Map.fetch!(:rows)
      |> List.flatten()

  def erase(owner), do: Mana.Privacy.erase([PostgresTest.ErasureDomain], owner)
end

defmodule Mana.ErasureStorageTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  import ErasureStorageTest.Files
  alias Mana.Storage.Local
  alias Mana.Uploads.Thumbnail
  alias PostgresTest.{ErasureFile, Harness}

  setup_all do: Harness.start!()

  setup do
    Harness.reset!()
    local_storage!()
  end

  defp drain(opts \\ []), do: Oban.drain_queue([queue: :default] ++ opts)

  test "an erasure that rolls back keeps the files' objects and leaves no job" do
    owner = Ash.UUID.generate()
    file = stored!(owner)
    assert Mana.Notifications.outbox?(ErasureFile)

    assert {:error, _} =
             Ash.transact(ErasureFile, fn ->
               :ok = erase(owner)
               assert Ash.read!(ErasureFile) == []
               assert jobs() == ["available"]
               assert objects(file) == both(file)
               {:error, :changed_my_mind}
             end)

    assert [%{id: id}] = Ash.read!(ErasureFile)
    assert id == file.id
    assert objects(file) == both(file)
    assert jobs() == []
    assert %{success: 0, failure: 0} = drain()
    assert objects(file) == both(file)
  end

  test "a committed erasure keeps the objects until its job deletes them" do
    owner = Ash.UUID.generate()
    file = stored!(owner)
    other = stored!(Ash.UUID.generate())

    :ok = erase(owner)

    assert [%{id: id}] = Ash.read!(ErasureFile)
    assert id == other.id
    assert objects(file) == both(file)
    assert jobs() == ["available"]

    assert %{success: 1} = drain()
    assert objects(file) == []
    assert objects(other) == both(other)
  end

  test "an object already gone counts as deleted" do
    owner = Ash.UUID.generate()
    file = stored!(owner)
    :ok = erase(owner)
    :ok = Mana.Storage.delete(file.storage_key)

    assert %{success: 1, failure: 0} = drain()
    assert objects(file) == []
    assert jobs() == ["completed"]
  end

  test "a deletion storage refuses is tried again" do
    owner = Ash.UUID.generate()
    file = stored!(owner)
    :ok = erase(owner)

    # A directory where the object was: the local store cannot delete it.
    path = Local.path(file.storage_key)
    File.rm!(path)
    File.mkdir_p!(Path.join(path, "held"))

    assert %{failure: 1} = drain()
    assert jobs() == ["retryable"]
    refute Mana.Storage.exists?(Thumbnail.key(file.storage_key))

    File.rm_rf!(path)
    assert %{success: 1} = drain(with_scheduled: true)
    assert jobs() == ["completed"]
  end

  test "destroying a file outside an erasure discards its objects the same way" do
    file = stored!(Ash.UUID.generate())

    Ash.destroy!(file)
    assert objects(file) == both(file)
    assert jobs() == ["available"]

    assert %{success: 1} = drain()
    assert objects(file) == []
  end

  test "a thumbnail stored after its file's objects were discarded is not left behind" do
    file = original!(Ash.UUID.generate())
    Ash.destroy!(file)
    assert %{success: 1} = drain()

    # The thumbnail job read the original before the discard job ran.
    :ok = Mana.Storage.put(file.storage_key, png(), "image/png")

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} =
             Thumbnail.make(ErasureFile, file, 64)

    assert objects(file) == [file.storage_key]
  end
end

defmodule Mana.ErasureStorageNotifierTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  import ErasureStorageTest.Files
  alias PostgresTest.{ErasureFile, Harness}

  setup_all do
    Harness.start!()
    stop_supervised!(Oban)
    :ok
  end

  setup do
    Harness.reset!()
    local_storage!()
  end

  test "without Oban, an erasure that rolls back keeps the files' objects" do
    owner = Ash.UUID.generate()
    file = stored!(owner)
    refute Mana.Notifications.outbox?(ErasureFile)

    assert {:error, _} =
             Ash.transact(ErasureFile, fn ->
               :ok = erase(owner)
               {:error, :changed_my_mind}
             end)

    assert [_] = Ash.read!(ErasureFile)
    assert objects(file) == both(file)
  end

  test "without Oban, the objects go once the erasure commits, not before" do
    owner = Ash.UUID.generate()
    file = stored!(owner)

    assert {:ok, :erased} =
             Ash.transact(ErasureFile, fn ->
               :ok = erase(owner)
               assert objects(file) == both(file)
               :erased
             end)

    assert Ash.read!(ErasureFile) == []
    assert objects(file) == []
    assert jobs() == []
  end
end
