defmodule Mana.Privacy do
  @moduledoc """
  The data-subject rights over every resource that declares `privacy`: an export
  of the person's rows (each through its declared projection) and their erasure.
  Resources whose subject is their own primary key (the identity itself) are
  erased last.
  """
  require Ash.Query

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
  `:keep` ones stay. A `Mana.Uploads` resource loses its stored objects (and thumbnails)
  before its rows, so a storage failure stops the erasure with the rows still
  pointing at what remains. `Mana.History` follows: the entries of the deleted
  records go with them, and the entries of records that stay (the other
  party's booking, a review) keep what happened but no longer say the subject
  did it (`actor_id` cleared, `via: "erased"`).
  """
  def erase(domains, subject_id) do
    all = resources(domains)

    for resource <- all, Mana.Resource.Info.privacy_erase!(resource) == :detach do
      resource
      |> by_subject(subject_id)
      |> Ash.bulk_update!(:detach, %{}, authorize?: false, strategy: [:stream], return_errors?: true)
    end

    erasable = Enum.filter(all, &(Mana.Resource.Info.privacy_erase!(&1) == :delete))
    erased = Enum.flat_map(erasable, &erased_subjects(&1, subject_id))

    erasable
    |> Enum.sort_by(&identity?/1)
    |> Enum.each(fn resource ->
      if Mana.Uploads in Spark.extensions(resource), do: delete_objects(resource, subject_id)
      action = Ash.Resource.Info.primary_action!(resource, :destroy)

      resource
      |> by_subject(subject_id)
      |> Ash.bulk_destroy!(action.name, %{}, authorize?: false, strategy: [:atomic, :atomic_batches, :stream], return_errors?: true)
    end)

    forget_history(domains, subject_id, erased)
  end

  defp erased_subjects(resource, subject_id) do
    if Mana.History in Spark.extensions(resource) do
      type = Mana.Entity.type(resource)
      for row <- resource |> by_subject(subject_id) |> Ash.read!(authorize?: false), do: {type, to_string(row.id)}
    else
      []
    end
  end

  defp forget_history(domains, subject_id, erased) do
    for domain <- domains, log <- Ash.Domain.Info.resources(domain), Mana.History.Log in Spark.extensions(log) do
      erased
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.each(fn {type, ids} ->
        log
        |> Ash.Query.filter(subject_type == ^type and subject_id in ^ids)
        |> Ash.bulk_destroy!(:destroy, %{}, authorize?: false, strategy: [:atomic, :atomic_batches, :stream], return_errors?: true)
      end)

      log
      |> Ash.Query.filter(actor_id == ^subject_id)
      |> Ash.bulk_update!(:forget, %{actor_id: nil, via: "erased"}, authorize?: false, strategy: [:atomic, :atomic_batches, :stream], return_errors?: true)
    end

    :ok
  end

  defp delete_objects(resource, subject_id) do
    resource
    |> by_subject(subject_id)
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(&[&1.storage_key, &1.thumbnail_key])
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn key ->
      case Mana.Storage.delete(key) do
        :ok -> :ok
        {:error, reason} -> raise "could not delete stored object #{key}: #{inspect(reason)}"
      end
    end)
  end

  defp resources(domains) do
    for domain <- domains,
        resource <- Ash.Domain.Info.resources(domain),
        Mana.Resource in Spark.extensions(resource),
        match?({:ok, _}, Mana.Resource.Info.privacy_subject(resource)),
        do: resource
  end

  defp by_subject(resource, id),
    do: Ash.Query.filter(resource, ^Ash.Expr.ref(Mana.Resource.Info.privacy_subject!(resource)) == ^id)

  defp identity?(resource), do: Ash.Resource.Info.primary_key(resource) == [Mana.Resource.Info.privacy_subject!(resource)]

  defp name(resource), do: resource |> Module.split() |> List.last() |> Macro.underscore()
end
