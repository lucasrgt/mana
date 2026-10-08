defmodule Mana.Attachments.Attach do
  @moduledoc false
  defstruct [:attribute, :kinds, :__identifier__, :__spark_metadata__]
end

defmodule Mana.Attachments do
  @moduledoc """
  Which uploaded files a resource holds, declared where the attribute lives:

      attachments do
        files MyApp.Files.Asset
        attach :cover_photo_id, kinds: [:property_photo]
        attach :gallery_ids, kinds: [:property_photo]
      end

  Every create or update that changes an attached attribute accepts only ready
  files of those kinds the actor owns (`upload.not_attachable` otherwise).
  `Mana.Uploads.Url` and `Mana.Uploads.Urls` read `files` and `kinds` from
  here, so a calculation names only the attribute. The contract carries
  `x-mana-attachments` (attribute, one or many, and per kind the accepted
  content types and size limit from the files resource's `uploads`), and the
  generated client exposes `<Type>Attachments.<attribute>`, which checks a
  picked file before uploading it. `fake/3` gives a Moment a stored, ready
  file of the right kind.
  """

  @attach %Spark.Dsl.Entity{
    name: :attach,
    target: Mana.Attachments.Attach,
    args: [:attribute],
    identifier: :attribute,
    schema: [
      attribute: [type: :atom, required: true, doc: "A `:uuid` (one file) or `{:array, :uuid}` (several) attribute."],
      kinds: [type: {:list, :atom}, required: true, doc: "Upload kinds of `files` this attribute accepts."]
    ]
  }

  @attachments %Spark.Dsl.Section{
    name: :attachments,
    entities: [@attach],
    schema: [files: [type: :atom, required: true, doc: "The resource using `Mana.Uploads`."]]
  }

  use Spark.Dsl.Extension, sections: [@attachments], transformers: [Mana.Attachments.Transformer]
  use Mana.Primitive, contract: "x-mana-attachments", catalog: "uploads", moments: [:fake, :observe]

  @doc "Moments `observe`: the file ids each attached attribute of `record` holds."
  def observe(record) do
    for attach <- declared(record.__struct__), into: %{} do
      {to_string(attach.attribute), Map.get(record, attach.attribute)}
    end
  end

  @png Base.decode64!("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

  def declared(resource), do: Spark.Dsl.Extension.get_entities(resource, [:attachments])
  def files(resource), do: Spark.Dsl.Extension.get_opt(resource, [:attachments], :files, nil)

  @doc "The attach declaration of `attribute`, or nil."
  def attach(resource, attribute) do
    if Mana.Attachments in Spark.extensions(resource), do: Enum.find(declared(resource), &(&1.attribute == attribute))
  end

  def many?(resource, attribute), do: match?({:array, _}, Ash.Resource.Info.attribute(resource, attribute).type)

  @impl Mana.Primitive
  def contract(resource) do
    files = files(resource)
    kinds = Map.new(Mana.Uploads.kinds(files), &{&1.name, &1})

    for attach <- declared(resource) do
      %{
        "attribute" => to_string(attach.attribute),
        "many" => many?(resource, attach.attribute),
        "kinds" =>
          for name <- attach.kinds, kind = kinds[name] do
            %{"name" => to_string(name), "accept" => Mana.Uploads.accepted(kind), "max_bytes" => kind.max_bytes}
            |> Map.merge(for {key, value} <- [max_side: kind.max_side, quality: kind.quality], value, into: %{}, do: {to_string(key), value})
          end
      }
      |> then(fn map ->
        case Ash.Resource.Info.attribute(resource, attach.attribute) do
          %{constraints: constraints} when is_list(constraints) ->
            if is_integer(constraints[:max_length]), do: Map.put(map, "max", constraints[:max_length]), else: map

          _ ->
            map
        end
      end)
    end
  end

  @doc """
  A stored, ready file for `attribute` of `resource`, owned by `owner_id`
  (a one-pixel PNG, or a minimal PDF when the kind takes no images), for
  Moments and tests.
  """
  def fake(resource, attribute, owner_id) do
    attach = attach(resource, attribute) || raise ArgumentError, "#{inspect(resource)} attaches no #{inspect(attribute)}"
    files = files(resource)
    kind = Enum.find(Mana.Uploads.kinds(files), &(&1.name == hd(attach.kinds)))
    {content_type, bytes} = if "image/png" in Mana.Uploads.accepted(kind), do: {"image/png", @png}, else: {"application/pdf", "%PDF-1.4\n%%EOF\n"}
    id = Ash.UUID.generate()
    key = "#{Mana.Uploads.prefix(files)}/#{owner_id}/#{kind.name}/#{id}"
    :ok = Mana.Storage.put(key, bytes, content_type)

    files
    |> Ash.Changeset.for_create(:register, %{id: id, owner_id: owner_id, kind: kind.name, content_type: content_type, size_bytes: byte_size(bytes), storage_key: key})
    |> Ash.create!(authorize?: false)
    |> Ash.update!(%{}, action: :mark_ready, authorize?: false)
  end
end

defmodule Mana.Attachments.Check do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    resource = changeset.resource

    Enum.reduce(Mana.Attachments.declared(resource), changeset, fn attach, changeset ->
      case Mana.Uploads.Attached.validate(
             changeset,
             [files: Mana.Attachments.files(resource), attributes: [attach.attribute], kinds: attach.kinds],
             context
           ) do
        :ok -> changeset
        {:error, error} -> Ash.Changeset.add_error(changeset, error)
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context) do
    if Enum.any?(Mana.Attachments.declared(changeset.resource), &Ash.Changeset.changing_attribute?(changeset, &1.attribute)),
      do: {:not_atomic, "attached files are checked against their owner"},
      else: {:ok, change(changeset, opts, context)}
  end
end

defmodule Mana.Attachments.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer

  def after?(_), do: false
  def before?(_), do: true

  def transform(dsl) do
    case Transformer.get_entities(dsl, [:attachments]) do
      [] -> {:ok, dsl}
      _ -> Ash.Resource.Builder.add_change(dsl, Mana.Attachments.Check, on: [:create, :update])
    end
  end
end
