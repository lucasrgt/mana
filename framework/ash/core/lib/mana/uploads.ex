defmodule Mana.Uploads.Kind do
  @moduledoc false
  defstruct [
    :name,
    :accept,
    :max_bytes,
    :thumbnail,
    :max_side,
    :quality,
    :__identifier__,
    :__spark_metadata__
  ]
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
  `request_upload` (a signed upload for the actor), `confirm` (an update of
  the file: ready once its object is in storage, a no-op once ready, and the
  thumbnail job inserted in the same transaction) and `mark_ready`. Who may
  call them stays in the resource's own policies, so `confirm` (and the
  read that finds the file) needs one such as
  `authorize_if expr(owner_id == ^actor(:id))`: nothing else stops one
  person confirming another's upload. Other resources bind these files with
  `Mana.Uploads.Attached` and read them with `Mana.Uploads.Urls`.

  Destroying a file (any destroy action, `Mana.Privacy.erase/2` included)
  deletes its object and thumbnail from storage only once the destroy
  commits, so a destroy that rolls back keeps both. Where the app runs Oban
  on the resource's repo (`Mana.Notifications.outbox?/1`), a job inserted
  in the destroy's transaction (`discard_queue`) deletes them, with up to 20
  attempts, and an object already gone counts as deleted. Without it,
  they are deleted once the outermost transaction commits (an Ash notifier):
  a bulk destroy then needs `notify?: true`, and a failure goes to the error
  reporter, not back to the caller.
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
      accept: [
        type: {:or, [{:in, [:images]}, {:list, {:or, [{:in, [:images]}, :string]}}]},
        default: :images
      ],
      max_bytes: [type: :pos_integer, default: 25_000_000],
      thumbnail: [
        type: :pos_integer,
        doc: "Longest edge, in pixels, of a JPEG thumbnail made once the image is ready."
      ],
      max_side: [
        type: :pos_integer,
        doc: "Longest edge, in pixels, clients shrink an image to before uploading it."
      ],
      quality: [type: {:in, 1..100}, doc: "JPEG quality clients re-encode a shrunk image with."]
    ]
  }

  @uploads %Spark.Dsl.Section{
    name: :uploads,
    entities: [@kind],
    schema: [
      kind_type: [
        type: :atom,
        doc: "A `Mana.Enum` naming the kinds, for a named API enum; atoms otherwise."
      ],
      prefix: [
        type: :string,
        default: "uploads",
        doc: "Storage keys read `<prefix>/<owner>/<kind>/<id>`."
      ],
      thumbnail_queue: [
        type: :atom,
        default: :default,
        doc: "The Oban queue that makes thumbnails."
      ],
      discard_queue: [
        type: :atom,
        default: :default,
        doc: "The Oban queue that deletes a destroyed file's objects."
      ]
    ]
  }

  use Spark.Dsl.Extension, sections: [@uploads], transformers: [Mana.Uploads.Transformer]

  alias Spark.Dsl.Extension

  def images, do: @images

  @doc "The content types a kind accepts."
  def accepted(%Mana.Uploads.Kind{accept: accept}),
    do: accept |> List.wrap() |> Enum.flat_map(&if(&1 == :images, do: @images, else: [&1]))

  def kinds(resource), do: Extension.get_entities(resource, [:uploads])
  def prefix(resource), do: Extension.get_opt(resource, [:uploads], :prefix, "uploads")

  def thumbnail_queue(resource),
    do: Extension.get_opt(resource, [:uploads], :thumbnail_queue, :default)

  def discard_queue(resource),
    do: Extension.get_opt(resource, [:uploads], :discard_queue, :default)

  @doc "The file ids a record or changeset holds in `attributes`, in order, each once."
  def ids(%Ash.Changeset{} = changeset, attributes),
    do: distinct(Enum.map(attributes, &Ash.Changeset.get_attribute(changeset, &1)))

  def ids(record, attributes), do: distinct(Enum.map(attributes, &Map.get(record, &1)))

  defp distinct(values),
    do: values |> Enum.flat_map(&List.wrap/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  @doc "A signed read link to the ready file `id`, or nil."
  def read_url(_files, nil, _ttl), do: nil

  def read_url(files, id, ttl) do
    case ready(files, [id]) do
      [file] ->
        %{
          url: Mana.Storage.read_url(file.storage_key, ttl),
          expires_at: DateTime.add(DateTime.utc_now(), ttl)
        }

      _ ->
        nil
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

        query =
          if opts[:images], do: Ash.Query.filter(query, content_type in ^@images), else: query

        query = if kinds = opts[:kinds], do: Ash.Query.filter(query, kind in ^kinds), else: query
        Ash.read!(query, authorize?: false)
    end
  end

  def error(:size_too_large),
    do:
      Mana.Error.new("upload.size_too_large", "the file is empty or too large",
        field: :size_bytes
      )

  def error(:content_type_invalid),
    do:
      Mana.Error.new("upload.content_type_invalid", "this kind of file is not accepted",
        field: :content_type
      )

  def error(:not_found), do: Mana.Error.new("upload.not_found", "no such upload", status: 404)

  def error(:not_uploaded),
    do: Mana.Error.new("upload.not_uploaded", "the file has not reached storage yet", status: 409)

  def error(:not_attachable),
    do:
      Mana.Error.new("upload.not_attachable", "only your own ready files can be attached",
        status: 403
      )

  def codes,
    do:
      ~w(upload.size_too_large upload.content_type_invalid upload.not_found upload.not_uploaded upload.not_attachable)
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
      kinds -> with {:ok, dsl} <- build(dsl, kinds), do: discard(dsl)
    end
  end

  defp discard(dsl) do
    notifiers = Transformer.get_persisted(dsl, :simple_notifiers, [])

    dsl
    |> Transformer.persist(
      :simple_notifiers,
      Enum.uniq(notifiers ++ [Mana.Uploads.Discard.Notifier])
    )
    |> Builder.add_change(Mana.Uploads.Discard, on: [:destroy])
  end

  defp build(dsl, kinds) do
    kind_type = Transformer.get_option(dsl, [:uploads], :kind_type)
    names = Enum.map(kinds, & &1.name)

    {kind_type, kind_constraints} =
      if kind_type, do: {kind_type, []}, else: {:atom, [one_of: names]}

    ticket = [
      asset_id: [type: :uuid, allow_nil?: false],
      url: [type: :string, allow_nil?: false],
      method: [type: :string, allow_nil?: false],
      headers_content_type: [type: :string, allow_nil?: false],
      expires_at: [type: :utc_datetime, allow_nil?: false]
    ]

    with {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :id, :uuid,
             primary_key?: true,
             allow_nil?: false,
             writable?: true,
             default: &Ash.UUID.generate/0,
             public?: true
           ),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :owner_id, :uuid, allow_nil?: false),
         {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :kind, kind_type,
             allow_nil?: false,
             public?: true,
             constraints: kind_constraints
           ),
         {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :content_type, :string,
             allow_nil?: false,
             public?: true
           ),
         {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :size_bytes, :integer, allow_nil?: false, public?: true),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :storage_key, :string, allow_nil?: false),
         {:ok, dsl} <-
           Builder.add_new_attribute(dsl, :status, :atom,
             allow_nil?: false,
             default: :uploading,
             public?: true,
             constraints: [one_of: [:uploading, :ready]]
           ),
         {:ok, dsl} <- Builder.add_new_attribute(dsl, :thumbnail_key, :string),
         {:ok, dsl} <- Builder.add_new_create_timestamp(dsl, :created_at, type: :utc_datetime),
         {:ok, dsl} <- Builder.add_new_update_timestamp(dsl, :updated_at, type: :utc_datetime),
         {:ok, dsl} <- Builder.add_new_action(dsl, :read, :read, primary?: true),
         {:ok, dsl} <- Builder.add_new_action(dsl, :destroy, :destroy, primary?: true),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :create, :register,
             primary?: true,
             accept: [:id, :owner_id, :kind, :content_type, :size_bytes, :storage_key]
           ),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :update, :mark_ready,
             accept: [],
             changes: [
               Builder.build_action_change(
                 {Ash.Resource.Change.SetAttribute, attribute: :status, value: :ready}
               )
             ]
           ),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :update, :attach_thumbnail, accept: [:thumbnail_key]),
         {:ok, kind_arg} <-
           Builder.build_action_argument(:kind, kind_type,
             allow_nil?: false,
             constraints: kind_constraints
           ),
         {:ok, type_arg} <-
           Builder.build_action_argument(:content_type, :string,
             allow_nil?: false,
             constraints: [max_length: 100]
           ),
         {:ok, size_arg} <-
           Builder.build_action_argument(:size_bytes, :integer, allow_nil?: false),
         {:ok, dsl} <-
           Builder.add_new_action(dsl, :action, :request_upload,
             returns: :map,
             constraints: [fields: ticket],
             arguments: [kind_arg, type_arg, size_arg],
             run: {Mana.Uploads.Request, []}
           ) do
      Builder.add_new_action(dsl, :update, :confirm,
        accept: [],
        require_atomic?: false,
        changes: [Builder.build_action_change(Mana.Uploads.Confirm)]
      )
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

        Ash.create!(
          resource,
          %{
            id: id,
            owner_id: actor.id,
            kind: kind,
            content_type: content_type,
            size_bytes: size,
            storage_key: key
          },
          action: :register,
          authorize?: false
        )

        upload = Mana.Storage.upload_url(key, content_type, 3600)

        {:ok,
         %{
           asset_id: id,
           url: upload.url,
           method: upload.method,
           headers_content_type: upload.content_type,
           expires_at: upload.expires_at
         }}
    end
  end
end

defmodule Mana.Uploads.Confirm do
  @moduledoc """
  Ready only once the object exists in storage; confirming a ready file
  changes nothing. Storage is asked before the transaction opens, so no lock
  waits on it; the thumbnail job is inserted in the transaction, so a confirm
  that rolls back leaves none, and one that cannot insert it fails.
  """
  use Ash.Resource.Change
  alias Mana.Uploads.Thumbnail

  @impl true
  def change(%{data: %{status: :ready}} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_transaction(&stored/1)
    |> Ash.Changeset.force_change_attribute(:status, :ready)
    |> Ash.Changeset.after_action(&thumbnail/2)
  end

  defp stored(changeset) do
    if Mana.Storage.exists?(changeset.data.storage_key),
      do: changeset,
      else: Ash.Changeset.add_error(changeset, Mana.Uploads.error(:not_uploaded))
  end

  defp thumbnail(changeset, file) do
    case Thumbnail.enqueue(changeset.resource, file) do
      :skip -> {:ok, file}
      {:ok, _job} -> {:ok, file}
      {:error, error} -> {:error, error}
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
  alias Mana.Uploads.Url

  @impl true
  def load(_, opts, _), do: List.wrap(opts[:attributes])

  @impl true
  def calculate([], _, _), do: []

  def calculate([record | _] = records, opts, _) do
    attributes = List.wrap(opts[:attributes])
    opts = Url.attached(record.__struct__, attributes, opts)
    ordered = &Mana.Uploads.ids(&1, attributes)
    ttl = opts[:ttl] || 3600

    ready =
      opts[:files]
      |> Mana.Uploads.ready(Enum.flat_map(records, ordered), kinds: opts[:kinds])
      |> Map.new(&{&1.id, &1})

    Enum.map(records, fn record ->
      for id <- ordered.(record),
          file = ready[id],
          do: %{asset_id: id, url: Mana.Storage.read_url(file.storage_key, ttl)}
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
      if file = ready[id],
        do: Mana.Storage.read_url(key(file, opts[:thumbnail]), opts[:ttl] || 3600)
    end)
  end

  @doc false
  def attached(resource, attributes, opts) do
    if opts[:files] do
      opts
    else
      attaches = Enum.map(attributes, &Mana.Attachments.attach(resource, &1))

      if attaches == [] or nil in attaches,
        do:
          raise(
            ArgumentError,
            "#{inspect(resource)} attaches none of #{inspect(attributes)}; pass files:"
          )

      opts
      |> Keyword.put(:files, Mana.Attachments.files(resource))
      |> Keyword.put_new(:kinds, Enum.flat_map(attaches, & &1.kinds))
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
  # Optional dependencies, called only when the app has them.
  @compile {:no_warn_undefined,
            [Mana.Uploads.Thumbnail.Worker, Oban, Vix.Vips.Image, Vix.Vips.Operation]}
  alias Ash.Resource.Info
  alias Mana.Uploads.Thumbnail.Worker
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

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
          |> Worker.new(queue: Mana.Uploads.thumbnail_queue(resource))
        end

      _ ->
        nil
    end
  end

  @doc "The thumbnail of `file`, stored and attached; `{:error, reason}` when it cannot be made."
  def make(resource, file, size) do
    with {:ok, original} <- Mana.Storage.get(file.storage_key),
         {:ok, jpeg} <- resize(original, size),
         key = key(file.storage_key),
         :ok <- Mana.Storage.put(key, jpeg, "image/jpeg") do
      attach(resource, file, key)
    end
  end

  @doc false
  def key(storage_key), do: storage_key <> ".thumb.jpg"

  # The file may be destroyed while its thumbnail is made, its objects
  # already discarded: the JPEG stored after that would outlive it. A failed
  # attach takes the JPEG back; a retried job makes it again.
  defp attach(resource, file, key) do
    with {:error, _} = error <-
           Ash.update(file, %{thumbnail_key: key},
             action: :attach_thumbnail,
             authorize?: false,
             domain: Info.domain(resource)
           ) do
      _ = Mana.Storage.delete(key)
      error
    end
  end

  defp resize(original, size) do
    with {:ok, image} <- Operation.thumbnail_buffer(original, size),
         do: Image.write_to_buffer(image, ".jpg[Q=82,strip]")
  end
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Uploads.Thumbnail.Worker do
    @moduledoc false
    use Oban.Worker, max_attempts: 5
    alias Mana.Uploads.Thumbnail

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"resource" => resource, "id" => id, "size" => size}}) do
      resource = Module.safe_concat([resource])

      case Ash.get(resource, id, authorize?: false) do
        {:ok, %{status: :ready, thumbnail_key: nil} = file} ->
          case Thumbnail.make(resource, file, size) do
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

defmodule Mana.Uploads.Discard do
  @moduledoc false
  # A file's objects go only once its destroy commits: deleted first, a
  # destroy that rolls back would keep rows naming objects that are gone.
  # The outbox's job is inserted here, inside the destroy's transaction, so
  # it commits or rolls back with the row; without the outbox
  # `Mana.Uploads.Discard.Notifier` deletes them after the commit.
  use Ash.Resource.Change

  # Optional dependencies, called only when the app has them.
  @compile {:no_warn_undefined, [Mana.Uploads.Discard.Worker, Oban]}
  alias Mana.Uploads.Discard.Worker
  alias Mana.Uploads.Thumbnail

  # Whether the job goes is decided once, here, and kept in the changeset's
  # context for the notifier: a destroy's notification carries the record as
  # it was before the after_action hooks, so their metadata never reaches it.
  @impl true
  def change(changeset, _opts, _context) do
    if Mana.Notifications.outbox?(changeset.resource),
      do:
        changeset
        |> Ash.Changeset.set_context(%{mana_discard: :queued})
        |> Ash.Changeset.after_action(&queue/2),
      else: changeset
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @doc false
  def queued?(%Ash.Changeset{context: %{mana_discard: :queued}}), do: true
  def queued?(_changeset), do: false

  defp queue(changeset, file) do
    %{"keys" => keys(file)}
    |> Worker.new(queue: Mana.Uploads.discard_queue(changeset.resource))
    |> Oban.insert()
    |> case do
      {:ok, _job} -> {:ok, file}
      {:error, error} -> {:error, error}
    end
  end

  # The thumbnail's key is asked for even when the row names none: its job
  # may have stored the JPEG without attaching it yet.
  @doc false
  def keys(file),
    do:
      [file.storage_key, file.thumbnail_key, Thumbnail.key(file.storage_key)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

  @doc false
  def delete(keys) do
    case for(key <- keys, {:error, reason} <- [Mana.Storage.delete(key)], do: {key, reason}) do
      [] -> :ok
      failed -> {:error, failed}
    end
  end
end

defmodule Mana.Uploads.Discard.Notifier do
  @moduledoc false
  # Without the outbox: an Ash notifier runs once the outermost transaction
  # commits and never for one that rolls back. The caller's destroy already
  # committed, so a storage failure is reported rather than raised.
  use Ash.Notifier
  alias Mana.Uploads.Discard
  alias Mana.Verbs.Report

  @impl true
  def notify(%Ash.Notifier.Notification{
        resource: resource,
        action: %{type: :destroy},
        changeset: changeset,
        data: file
      }) do
    with false <- Discard.queued?(changeset),
         {:error, failed} <- Discard.delete(Discard.keys(file)) do
      Report.error(
        RuntimeError.exception("stored objects not deleted: #{inspect(failed)}"),
        %{resource: resource, id: file.id}
      )
    end

    :ok
  end

  def notify(_notification), do: :ok
end

if Code.ensure_loaded?(Oban.Worker) do
  defmodule Mana.Uploads.Discard.Worker do
    @moduledoc false
    # Storage adapters answer `:ok` for a key already gone, so a job that
    # deleted some keys before failing deletes only the rest on its retry.
    use Oban.Worker, max_attempts: 20
    alias Mana.Uploads.Discard

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"keys" => keys}}), do: Discard.delete(keys)
  end
end
