defmodule Mana.Privacy do
  @moduledoc """
  The data-subject rights over every resource that declares `privacy`: an export
  of the person's rows (each through its declared projection) and their erasure.
  Resources whose subject is their own primary key (the identity itself) are
  erased last.
  """
  require Ash.Query
  alias Mana.History.Log

  @doc "`%{\"vehicle_registration\" => [%{plate: ..}], ..}` for `subject_id`."
  def export(domains, subject_id) do
    for resource <- resources(domains), into: %{} do
      fields = Mana.Resource.Info.privacy_export!(resource)

      rows =
        resource
        |> by_subject(subject_id)
        |> Ash.Query.load(Enum.filter(fields, &Ash.Resource.Info.calculation(resource, &1)))
        |> Ash.read!(authorize?: false)
        |> Enum.map(&Map.take(&1, fields))

      {name(resource), rows}
    end
  end

  @doc """
  Detaches the subject's rows of every `erase :detach` resource (their
  `detach` action), then deletes the rows of every `erase :delete` one;
  `:keep` ones stay. A `Mana.Uploads` resource's stored objects (and
  thumbnails) are deleted only once the destroy of their rows commits (see
  `Mana.Uploads`): an erasure that rolls back keeps them, and one that
  commits leaves them to a retried job (or, without Oban, to a notifier).
  `Mana.History` follows: the entries of the deleted
  records go with them, and the entries of records that stay (the subject's
  kept or detached rows, and whatever the subject did to others' records)
  keep what happened but no longer say the subject did it (`actor_id`
  cleared, `via: "erased"`) nor what the subject's personal fields held:
  every field of `personal/1` reads `"[erased]"` in the entry's `params`,
  `before` and `after`. The erasure's own changes notify like any other
  action (`Mana.Entity` announcements, history telemetry).

  Everything it does follows the transaction it runs in, stored objects
  included, so it belongs inside the one that also closes the account: an
  erasure that rolls back leaves the person as they were.
  """
  def erase(domains, subject_id) do
    all = resources(domains)

    kept =
      for resource <- all,
          ids = kept_subjects(resource, subject_id),
          into: %{},
          do: {resource, ids}

    for resource <- all, Mana.Resource.Info.privacy_erase!(resource) == :detach do
      resource
      |> by_subject(subject_id)
      |> Ash.bulk_update!(:detach, %{},
        authorize?: false,
        strategy: [:stream],
        notify?: true,
        return_errors?: true
      )
    end

    erasable = Enum.filter(all, &(Mana.Resource.Info.privacy_erase!(&1) == :delete))
    erased = Enum.flat_map(erasable, &erased_subjects(&1, subject_id))

    erasable
    |> Enum.sort_by(&identity?/1)
    |> Enum.each(fn resource ->
      action = Ash.Resource.Info.primary_action!(resource, :destroy)

      resource
      |> by_subject(subject_id)
      |> Ash.bulk_destroy!(action.name, %{},
        authorize?: false,
        strategy: [:atomic, :atomic_batches, :stream],
        notify?: true,
        return_errors?: true
      )
    end)

    forget_history(domains, subject_id, erased, kept)
  end

  # Read before `detach` cuts the rows from the subject.
  defp kept_subjects(resource, subject_id) do
    if Mana.Resource.Info.privacy_erase!(resource) != :delete and
         Mana.History in Spark.extensions(resource) do
      for row <- resource |> by_subject(subject_id) |> Ash.read!(authorize?: false),
          do: to_string(row.id)
    end
  end

  defp erased_subjects(resource, subject_id) do
    if Mana.History in Spark.extensions(resource) do
      type = Mana.Entity.type(resource)

      for row <- resource |> by_subject(subject_id) |> Ash.read!(authorize?: false),
          do: {type, to_string(row.id)}
    else
      []
    end
  end

  defp forget_history(domains, subject_id, erased, kept) do
    for domain <- domains,
        log <- Ash.Domain.Info.resources(domain),
        Log in Spark.extensions(log) do
      erased
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.each(fn {type, ids} ->
        log
        |> Ash.Query.filter(subject_type == ^type and subject_id in ^ids)
        |> Ash.bulk_destroy!(:destroy, %{},
          authorize?: false,
          strategy: [:atomic, :atomic_batches, :stream],
          return_errors?: true
        )
      end)

      scrub(log, subject_id, kept)

      log
      |> Ash.Query.filter(actor_id == ^subject_id)
      |> Ash.bulk_update!(:forget, %{actor_id: nil, via: "erased"},
        authorize?: false,
        strategy: [:atomic, :atomic_batches, :stream],
        return_errors?: true
      )
    end

    :ok
  end

  defp scrub(log, subject_id, kept) do
    for subject <- Log.subjects(log),
        fields = personal(subject),
        fields != [] do
      type = Mana.Entity.type(subject)
      ids = Map.get(kept, subject, [])

      log
      |> Ash.Query.filter(
        subject_type == ^type and (subject_id in ^ids or actor_id == ^subject_id)
      )
      |> Ash.bulk_update!(:scrub, %{fields: fields},
        authorize?: false,
        strategy: [:stream],
        allow_stream_with: :full_read,
        return_errors?: true
      )
    end
  end

  @doc """
  The fields of `resource` that hold a person's own data, as strings: its
  privacy `personal` fields (every `export` field when `personal` is not
  given) and its history `redact` ones. What an erasure scrubs from the
  history that stays and an incident (`Mana.Incident`) replaces; the rest
  of an export (a status, a total) is the person's record, not who they
  are.
  """
  def personal(resource) do
    declared =
      if Mana.Resource in Spark.extensions(resource) do
        case Mana.Resource.Info.privacy_personal(resource) do
          {:ok, fields} -> fields
          :error -> Mana.Resource.Info.privacy_export!(resource)
        end
      else
        []
      end

    redacted =
      if Mana.History in Spark.extensions(resource), do: Mana.History.redact(resource), else: []

    declared |> Enum.concat(redacted) |> Enum.uniq() |> Enum.map(&to_string/1)
  end

  defp resources(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        privacy?(resource),
        do: resource
  end

  defp privacy?(resource),
    do:
      Mana.Resource in Spark.extensions(resource) and
        match?({:ok, _}, Mana.Resource.Info.privacy_subject(resource))

  defp by_subject(resource, id),
    do:
      Ash.Query.filter(
        resource,
        ^Ash.Expr.ref(Mana.Resource.Info.privacy_subject!(resource)) == ^id
      )

  defp identity?(resource),
    do: Ash.Resource.Info.primary_key(resource) == [Mana.Resource.Info.privacy_subject!(resource)]

  defp name(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore()
end
