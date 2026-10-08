defmodule Mana.Uploads.Kind do
  @moduledoc false
  defstruct [:name, :accept, :max_bytes, :thumbnail, :max_side, :quality, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Uploads do
  @moduledoc """
  A resource of files people upload straight to `Mana.Storage` through signed
  URLs: asked for (`uploading`), then `ready` once the object exists.

      uploads do
        kind :property_photo, accept: :images, max_bytes: 25_000_000, thumbnail: 320
        kind :document, accept: [:images, "application/pdf"]
      end

  `max_side:` and `quality:` reach clients through `x-mana-attachments`:
  an image is shrunk to that longest edge and re-encoded before it leaves
  the device, so a phone's 12 MP photo does not cost the upload.

  A kind with `thumbnail:` also gets, once ready, a JPEG at most that many
  pixels on its longest edge, made by an Oban job (`thumbnail_queue`) with
  libvips (`:vix`); `Mana.Uploads.Url` serves it with `thumbnail: true` and
  falls back to the original until it exists.

  It adds the file's attributes (`owner_id`, `kind`, `content_type`,
  `size_bytes`, `storage_key`, `status`, timestamps) and the actions
  `request_upload` (a signed upload for the actor), `confirm` (ready once
  stored) and `mark_ready`. Who may call them stays in the resource's own
  policies. Other resources bind these files with `Mana.Uploads.Attached`
  and read them with `Mana.Uploads.Urls`.
  """
  require Ash.Query

  @images ~w(image/jpeg image/png image/webp)

  @kind %Spark.Dsl.Entity{
    name: :kind,
    target: Mana.Uploads.Kind,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      accept: [type: {:or, [{:in, [:images]}, {:list, {:or, [{:in, [:images]}, :string]}}]}, default: :images],
      max_bytes: [type: :pos_integer, default: 25_000_000],
      thumbnail: [type: :pos_integer, doc: "Longest edge, in pixels, of a JPEG thumbnail made once the image is ready."],
      max_side: [type: :pos_integer, doc: "Longest edge, in pixels, clients shrink an image to before uploading it."],
      quality: [type: {:in, 1..100}, doc: "JPEG quality clients re-encode a shrunk image with."]
    ]
  }

  @uploads %Spark.Dsl.Section{
    name: :uploads,
    entities: [@kind],
    schema: [
      kind_type: [type: :atom, doc: "A `Mana.Enum` naming the kinds, for a named API enum; atoms otherwise."],
      prefix: [type: :string, default: "uploads", doc: "Storage keys read `<prefix>/<owner>/<kind>/<id>`."],
      thumbnail_queue: [type: :atom, default: :default, doc: "The Oban queue that makes thumbnails."]
    ]
  }

  use Spark.Dsl.Extension, sections: [@uploads], transformers: [Mana.Uploads.Transformer]

  def images, do: @images

  @doc "The content types a kind accepts."
  def accepted(%Mana.Uploads.Kind{accept: accept}),
    do: accept |> List.wrap() |> Enum.flat_map(&if(&1 == :images, do: @images, else: [&1]))

  def kinds(resource), do: Spark.Dsl.Extension.get_entities(resource, [:uploads])
  def prefix(resource), do: Spark.Dsl.Extension.get_opt(resource, [:uploads], :prefix, "uploads")
  def thumbnail_queue(resource), do: Spark.Dsl.Extension.get_opt(resource, [:uploads], :thumbnail_queue, :default)

  @doc "The file ids a record or changeset holds in `attributes`, in order, each once."
  def ids(%Ash.Changeset{} = changeset, attributes),
    do: distinct(Enum.map(attributes, &Ash.Changeset.get_attribute(changeset, &1)))

  def ids(record, attributes), do: distinct(Enum.map(attributes, &Map.get(record, &1)))

  defp distinct(values), do: values |> Enum.flat_map(&List.wrap/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  @doc "A signed read link to the ready file `id`, or nil."
  def read_url(_files, nil, _ttl), do: nil

  def read_url(files, id, ttl) do
    case ready(files, [id]) do
      [file] -> %{url: Mana.Storage.read_url(file.storage_key, ttl), expires_at: DateTime.add(DateTime.utc_now(), ttl)}
      _ -> nil
    end
  end

  @doc "Whether every one of `ids` is a ready file `owner` uploaded (of `kinds`, when given)."
  def owned?(files, ids, owner, opts \\ []) do
    case distinct(ids) do
      [] ->
        true

      ids ->
        query = Ash.Query.filter(files, id in ^ids and owner_id == ^owner and status == :ready)
        query = if kinds = opts[:kinds], do: Ash.Query.filter(query, kind in ^kinds), else: query
        Ash.count!(query, authorize?: false) == length(ids)
    end
  end

  @doc "Which of `ids` are ready files of `files`, optionally only images."
  def ready(files, ids, opts \\ []) do
    case distinct(ids) do
      [] ->
        []

      ids ->
        query = Ash.Query.filter(files, id in ^ids and status == :ready)
        query = if opts[:images], do: Ash.Query.filter(query, content_type in ^@images), else: query
        query = if kinds = opts[:kinds], do: Ash.Query.filter(query, kind in ^kinds), else: query
        Ash.read!(query, authorize?: false)
    end
  end

  def error(:size_too_large), do: Mana.Error.new("upload.size_too_large", "the file is empty or too large", field: :size_bytes)
  def error(:content_type_invalid), do: Mana.Error.new("upload.content_type_invalid", "this kind of file is not accepted", field: :content_type)
  def error(:not_found), do: Mana.Error.new("upload.not_found", "no such upload", status: 404)
  def error(:not_uploaded), do: Mana.Error.new("upload.not_uploaded", "the file has not reached storage yet", status: 409)
  def error(:not_attachable), do: Mana.Error.new("upload.not_attachable", "only your own ready files can be attached", status: 403)

  def codes, do: ~w(upload.size_too_large upload.content_type_invalid upload.not_found upload.not_uploaded upload.not_attachable)
end

defmodule Mana.Uploads.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(_), do: true

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:uploads]) do
      [] -> {:ok, dsl}
      kinds -> build(dsl, kinds)
    end
  end

  defp build(dsl, kinds) do
    kind_type = Transformer.get_option(dsl, [:uploads], :kind_type)
    names = Enum.map(kinds, & &1.name)
    {kind_type, kind_constraints} = if kind_type, do: {kind_type, []}, else: {:atom, [one_of: names]}
    ticket = [
      asset_id: [type: :uuid, allow_nil?: false],
      url: [type: :string, allow_nil?: false],
      method: [type: :string, allow_nil?: false],
      headers_content_type: [type: :string, allow_nil?: false],
      expires_at: [type: :utc_datetime, allow_nil?: false]
    ]

    with {:ok, dsl} <- Builder.add_new_attribute(dsl, :id, :uuid, primary_key?: true, allow_nil?: false, writable?: true, default: &Ash.UUID.generate/0, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :owner_id, :uuid, allow_nil?: false),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :kind, kind_type, allow_nil?: false, public?: true, constraints: kind_constraints),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :content_type, :string, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :size_bytes, :integer, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :storage_key, :string, allow_nil?: false),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :status, :atom, allow_nil?: false, default: :uploading, public?: true, constraints: [one_of: [:uploading, :ready]]),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :thumbnail_key, :string),
         {:ok, dsl} <- Builder.add_new_create_timestamp(dsl, :created_at, type: :utc_datetime),
         {:ok, dsl} <- Builder.add_new_update_timestamp(dsl, :updated_at, type: :utc_datetime),
         {:ok, dsl} <- Builder.add_new_action(dsl, :read, :read, primary?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :destroy, :destroy, primary?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :create, :register, primary?: true, accept: [:id, :owner_id, :kind, :content_type, :size_bytes, :storage_key]),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :update, :mark_ready,
             accept: [],
             changes: [Builder.build_action_change({Ash.Resource.Change.SetAttribute, attribute: :status, value: :ready})]
           ),
         {:ok, dsl} <- Builder.add_new_action(dsl, :update, :attach_thumbnail, accept: [:thumbnail_key]),
         {:ok, kind_arg} <- Builder.build_action_argument(:kind, kind_type, allow_nil?: false, constraints: kind_constraints),
         {:ok, type_arg} <- Builder.build_action_argument(:content_type, :string, allow_nil?: false, constraints: [max_length: 100]),
         {:ok, size_arg} <- Builder.build_action_argument(:size_bytes, :integer, allow_nil?: false),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :action, :request_upload,
             returns: :map,
             constraints: [fields: ticket],
             arguments: [kind_arg, type_arg, size_arg],
             run: {Mana.Uploads.Request, []}
           ),
         {:ok, id_arg} <- Builder.build_action_argument(:id, :uuid, allow_nil?: false),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :action, :confirm,
             returns: :map,
             constraints: [fields: [asset_id: [type: :uuid, allow_nil?: false], status: [type: :atom, allow_nil?: false, constraints: [one_of: [:uploading, :ready]]]]],
             arguments: [id_arg],
             run: {Mana.Uploads.Confirm, []}
           ) do
      {:ok, dsl}
    end
  end
end

defmodule Mana.Uploads.Request do
  @moduledoc "A signed upload for the actor, recorded as `uploading` under `<resource>/<owner>/<kind>/<id>`."
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _, %{actor: actor}) do
    resource = input.resource
    %{kind: kind, size_bytes: size} = input.arguments
    content_type = String.downcase(input.arguments.content_type)
    rule = Enum.find(Mana.Uploads.kinds(resource), &(&1.name == kind))

    cond do
      size <= 0 or size > rule.max_bytes ->
        {:error, Mana.Uploads.error(:size_too_large)}

      content_type not in Mana.Uploads.accepted(rule) ->
        {:error, Mana.Uploads.error(:content_type_invalid)}

      true ->
        id = Ash.UUID.generate()
        key = "#{Mana.Uploads.prefix(resource)}/#{actor.id}/#{kind}/#{id}"

        Ash.create!(resource, %{id: id, owner_id: actor.id, kind: kind, content_type: content_type, size_bytes: size, storage_key: key},
          action: :register,
          authorize?: false
        )

        upload = Mana.Storage.upload_url(key, content_type, 3600)
        {:ok, %{asset_id: id, url: upload.url, method: upload.method, headers_content_type: upload.content_type, expires_at: upload.expires_at}}
    end
  end
end

defmodule Mana.Uploads.Confirm do
  @moduledoc "Ready only once the object exists in storage; confirming again is a no-op."
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  @impl true
  def run(input, _, %{actor: actor}) do
    input.resource
    |> Ash.Query.filter(id == ^input.arguments.id and owner_id == ^actor.id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        {:error, Mana.Uploads.error(:not_found)}

      %{status: :ready} = file ->
        {:ok, %{asset_id: file.id, status: :ready}}

      file ->
        if Mana.Storage.exists?(file.storage_key) do
          ready = Ash.update!(file, %{}, action: :mark_ready, authorize?: false)
          Mana.Uploads.Thumbnail.enqueue(input.resource, ready)
          {:ok, %{asset_id: ready.id, status: ready.status}}
        else
          {:error, Mana.Uploads.error(:not_uploaded)}
        end
    end
  end
end

defmodule Mana.Uploads.Attached do
  @moduledoc """
  Files bound to a record must be ready uploads the actor owns, never someone
  else's: `validate {Mana.Uploads.Attached, files: MyApp.Asset, attributes: [:cover_id, :gallery_ids]}`;
  `kinds:` narrows which. Checked only when one of the attributes changes.
  """
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def init(opts) do
    if opts[:files] && opts[:attributes] != [],
      do: {:ok, opts},
      else: {:error, "`files` (the uploads resource) and `attributes` are required"}
  end

  @impl true
  def validate(changeset, opts, context) do
    attributes = List.wrap(opts[:attributes])

    if Enum.any?(attributes, &Ash.Changeset.changing_attribute?(changeset, &1)) do
      ids = Mana.Uploads.ids(changeset, attributes)
      owner = context.actor && context.actor.id

      if Mana.Uploads.owned?(opts[:files], ids, owner, kinds: opts[:kinds]),
        do: :ok,
        else: {:error, Mana.Uploads.error(:not_attachable)}
    else
      :ok
    end
  end
end

defmodule Mana.Uploads.Urls do
  @moduledoc """
  The record's ready files in attribute order, each with a signed read URL:
  `calculate :photos, {:array, :map}, {Mana.Uploads.Urls, files: MyApp.Asset, attributes: [:cover_id, :gallery_ids]}`.
  Files not ready (or gone) are left out. On a resource with `Mana.Attachments`,
  `files` and `kinds` come from its `attach` declarations.
  """
  use Ash.Resource.Calculation
  require Ash.Query

  @impl true
  def load(_, opts, _), do: List.wrap(opts[:attributes])

  @impl true
  def calculate([], _, _), do: []

  def calculate([record | _] = records, opts, _) do
    attributes = List.wrap(opts[:attributes])
    opts = Mana.Uploads.Url.attached(record.__struct__, attributes, opts)
    ordered = &Mana.Uploads.ids(&1, attributes)
    ttl = opts[:ttl] || 3600

    ready =
      opts[:files]
      |> Mana.Uploads.ready(Enum.flat_map(records, ordered), kinds: opts[:kinds])
      |> Map.new(&{&1.id, &1})

    Enum.map(records, fn record ->
      for id <- ordered.(record), file = ready[id], do: %{asset_id: id, url: Mana.Storage.read_url(file.storage_key, ttl)}
    end)
  end
end

defmodule Mana.Uploads.Url do
  @moduledoc """
  A signed read URL for the one file an attribute names, or nil when it is
  unset or not ready: `calculate :photo_url, :string, {Mana.Uploads.Url, files: MyApp.Asset, attribute: :photo_id}`.
  """
  use Ash.Resource.Calculation

  @impl true
  def load(_, opts, _), do: [opts[:attribute]]

  @impl true
  def calculate([], _, _), do: []

  def calculate([record | _] = records, opts, _) do
    opts = attached(record.__struct__, [opts[:attribute]], opts)
    ids = Enum.map(records, &Map.get(&1, opts[:attribute]))
    ready = opts[:files] |> Mana.Uploads.ready(ids, kinds: opts[:kinds]) |> Map.new(&{&1.id, &1})

    Enum.map(ids, fn id ->
      if file = ready[id], do: Mana.Storage.read_url(key(file, opts[:thumbnail]), opts[:ttl] || 3600)
    end)
  end

  @doc false
  def attached(resource, attributes, opts) do
    if opts[:files] do
      opts
    else
      attaches = Enum.map(attributes, &Mana.Attachments.attach(resource, &1))
      if attaches == [] or nil in attaches, do: raise(ArgumentError, "#{inspect(resource)} attaches none of #{inspect(attributes)}; pass files:")
      opts |> Keyword.put(:files, Mana.Attachments.files(resource)) |> Keyword.put_new(:kinds, Enum.flat_map(attaches, & &1.kinds))
    end
  end

  defp key(%{thumbnail_key: thumbnail}, true) when is_binary(thumbnail), do: thumbnail
  defp key(file, _), do: file.storage_key
end

defmodule Mana.Uploads.Thumbnail do
  @moduledoc """
  Makes the thumbnail of a ready image whose kind asks for one, beside the
  original (`<key>.thumb.jpg`). An image libvips cannot read keeps no thumbnail
  and its readers keep the original.
  """
  require Logger

  def enqueue(resource, file) do
    case job(resource, file) do
      nil -> :skip
      job -> Oban.insert(job)
    end
  end

  @doc "The Oban job that makes `file`'s thumbnail, or nil when its kind keeps none; insert it with the repo when Oban is not running."
  def job(resource, file) do
    case Enum.find(Mana.Uploads.kinds(resource), &(&1.name == file.kind)) do
      %{thumbnail: size} when is_integer(size) and is_binary(file.content_type) ->
        if file.content_type in Mana.Uploads.images() and Code.ensure_loaded?(Oban) do
          %{"resource" => inspect(resource), "id" => file.id, "size" => size}
          |> Mana.Uploads.Thumbnail.Worker.new(queue: Mana.Uploads.thumbnail_queue(resource))
        end

      _ ->
        nil
    end
  end

  @doc "The thumbnail of `file`, stored and attached; `{:error, reason}` when it cannot be made."
  def make(resource, file, size) do
    with {:ok, original} <- Mana.Storage.get(file.storage_key),
         {:ok, jpeg} <- resize(original, size),
         key = file.storage_key <> ".thumb.jpg",
         :ok <- Mana.Storage.put(key, jpeg, "image/jpeg") do
      Ash.update(file, %{thumbnail_key: key}, action: :attach_thumbnail, authorize?: false, domain: Ash.Resource.Info.domain(resource))
    end
  end

  defp resize(original, size) do
    with {:ok, image} <- Vix.Vips.Operation.thumbnail_buffer(original, size),
         do: Vix.Vips.Image.write_to_buffer(image, ".jpg[Q=82,strip]")
  end
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Uploads.Thumbnail.Worker do
    @moduledoc false
    use Oban.Worker, max_attempts: 5

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"resource" => resource, "id" => id, "size" => size}}) do
      resource = Module.safe_concat([resource])

      case Ash.get(resource, id, authorize?: false) do
        {:ok, %{status: :ready, thumbnail_key: nil} = file} ->
          case Mana.Uploads.Thumbnail.make(resource, file, size) do
            {:ok, _} -> :ok
            # libvips answers an image it cannot read with a message; retrying will not help.
            {:error, reason} when is_binary(reason) -> {:cancel, reason}
            error -> error
          end

        _ ->
          :ok
      end
    end
  end
end
