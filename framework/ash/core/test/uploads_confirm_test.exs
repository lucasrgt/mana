defmodule UploadsConfirmTest.File do
  @moduledoc false
  use Ash.Resource,
    domain: UploadsConfirmTest.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [Mana.Uploads],
    authorizers: [Ash.Policy.Authorizer]

  uploads do
    kind(:photo, max_bytes: 1_000)
  end

  policies do
    policy action(:request_upload) do
      authorize_if(actor_present())
    end

    policy action([:read, :confirm]) do
      authorize_if(expr(owner_id == ^actor(:id)))
    end
  end
end

defmodule UploadsConfirmTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(UploadsConfirmTest.File)
  end
end

defmodule Mana.UploadsConfirmTest do
  use ExUnit.Case, async: false

  alias UploadsConfirmTest.File, as: Upload

  setup do
    root = Path.join(System.tmp_dir!(), "mana-uploads-#{System.unique_integer([:positive])}")
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

    owner = %{id: Ash.UUID.generate()}

    %{asset_id: id} =
      Upload
      |> Ash.ActionInput.for_action(
        :request_upload,
        %{kind: :photo, content_type: "image/jpeg", size_bytes: 10},
        actor: owner
      )
      |> Ash.run_action!()

    %{owner: owner, upload: Ash.get!(Upload, id, actor: owner)}
  end

  test "the owner confirms a stored upload; confirming it again changes nothing", %{
    owner: owner,
    upload: file
  } do
    :ok = Mana.Storage.put(file.storage_key, "jpeg", "image/jpeg")

    assert {:ok, %{status: :ready} = ready} =
             Ash.update(file, %{}, action: :confirm, actor: owner)

    assert {:ok, %{status: :ready}} = Ash.update(ready, %{}, action: :confirm, actor: owner)
  end

  test "an upload not yet in storage is not confirmed", %{owner: owner, upload: file} do
    assert {:error, error} = Ash.update(file, %{}, action: :confirm, actor: owner)
    assert [%Mana.Error{code: "upload.not_uploaded"}] = Ash.Error.to_error_class(error).errors
    assert Ash.get!(Upload, file.id, actor: owner).status == :uploading
  end

  test "someone else's upload is theirs to confirm: the policies refuse it", %{upload: file} do
    :ok = Mana.Storage.put(file.storage_key, "jpeg", "image/jpeg")
    stranger = %{id: Ash.UUID.generate()}

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(file, %{}, action: :confirm, actor: stranger)

    assert {:error, _} = Ash.get(Upload, file.id, actor: stranger)
  end
end
