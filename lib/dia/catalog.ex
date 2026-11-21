defmodule Dia.Catalog do
  @moduledoc """
  Manages local DICOM archive sources, indexed Study/Series/Instance hierarchies,
  quarantined ingest errors, and faceted metadata search.
  """

  import Ecto.Query

  alias Dia.Repo
  alias Dia.Catalog.{ArchiveSource, IngestError, Instance, Series, Study}

  # Archive Sources

  def list_archive_sources do
    ArchiveSource
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  def get_archive_source!(id), do: Repo.get!(ArchiveSource, id)

  def get_archive_source(id), do: Repo.get(ArchiveSource, id)

  def change_archive_source(%ArchiveSource{} = source, attrs \\ %{}) do
    ArchiveSource.changeset(source, attrs)
  end

  def create_archive_source(attrs) do
    %ArchiveSource{}
    |> ArchiveSource.changeset(attrs)
    |> Repo.insert()
  end

  def update_archive_source_status(%ArchiveSource{} = source, attrs) do
    source
    |> ArchiveSource.scan_status_changeset(attrs)
    |> Repo.update()
  end

  def delete_archive_source(%ArchiveSource{} = source) do
    result = Repo.delete(source)
    prune_empty_hierarchy()
    result
  end

  def clear_ingest_errors(archive_source_id) do
    from(e in IngestError, where: e.archive_source_id == ^archive_source_id)
    |> Repo.delete_all()
  end

  def record_ingest_error(archive_source_id, file_path, reason) do
    %IngestError{archive_source_id: archive_source_id}
    |> IngestError.changeset(%{
      file_path: to_string(file_path),
      error_reason: format_reason(reason)
    })
    |> Repo.insert()
  end

  def list_ingest_errors(archive_source_id \\ nil, limit \\ 50) do
    query =
      IngestError
      |> preload(:archive_source)
      |> order_by([e], desc: e.inserted_at)
      |> limit(^limit)

    query =
      if archive_source_id do
        where(query, [e], e.archive_source_id == ^archive_source_id)
      else
        query
      end

    Repo.all(query)
  end

  # Indexing Upserts

  def upsert_dicom_metadata(archive_source_id, meta) when is_map(meta) do
    Repo.transaction(fn ->
      study = upsert_study!(meta)
      series = upsert_series!(study, meta)
      instance = upsert_instance!(archive_source_id, study, series, meta)
      {study, series, instance}
    end)
  end

  def refresh_aggregates do
    series_list = Repo.all(Series)

    Enum.each(series_list, fn s ->
      count = Repo.aggregate(from(i in Instance, where: i.series_id == ^s.id), :count)

      from(sr in Series, where: sr.id == ^s.id)
      |> Repo.update_all(set: [instance_count: count])
    end)

    studies = Repo.all(Study)

    Enum.each(studies, fn st ->
      series_rows =
        from(s in Series,
          where: s.study_id == ^st.id,
          select: {s.modality, s.instance_count}
        )
        |> Repo.all()

      series_count = length(series_rows)
      instance_count = Enum.reduce(series_rows, 0, fn {_, c}, acc -> acc + c end)

      modalities =
        series_rows
        |> Enum.map(fn {m, _} -> m end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.join(",")

      from(study in Study, where: study.id == ^st.id)
      |> Repo.update_all(
        set: [
          series_count: series_count,
          instance_count: instance_count,
          modalities: modalities
        ]
      )
    end)

    :ok
  end

  def prune_empty_hierarchy do
    referenced_series = from(i in Instance, select: i.series_id)

    from(s in Series, where: s.id not in subquery(referenced_series))
    |> Repo.delete_all()

    referenced_studies = from(s in Series, select: s.study_id)

    from(st in Study, where: st.id not in subquery(referenced_studies))
    |> Repo.delete_all()

    refresh_aggregates()
  end

  # Faceted Search & Explorer

  def catalog_stats do
    %{
      archive_sources: Repo.aggregate(ArchiveSource, :count),
      studies: Repo.aggregate(Study, :count),
      series: Repo.aggregate(Series, :count),
      instances: Repo.aggregate(Instance, :count),
      ingest_errors: Repo.aggregate(IngestError, :count)
    }
  end

  def list_filter_facets do
    modalities =
      from(s in Series,
        where: not is_nil(s.modality) and s.modality != "",
        distinct: true,
        order_by: s.modality,
        select: s.modality
      )
      |> Repo.all()

    body_parts =
      from(s in Series,
        where: not is_nil(s.body_part_examined) and s.body_part_examined != "",
        distinct: true,
        order_by: s.body_part_examined,
        select: s.body_part_examined
      )
      |> Repo.all()

    institutions =
      from(st in Study,
        where: not is_nil(st.institution_name) and st.institution_name != "",
        distinct: true,
        order_by: st.institution_name,
        select: st.institution_name
      )
      |> Repo.all()

    %{
      modalities: modalities,
      body_parts: body_parts,
      institutions: institutions
    }
  end

  def search_series(filters \\ %{}) do
    filters = normalize_filters(filters)

    base =
      from(s in Series,
        join: st in assoc(s, :study),
        preload: [study: st],
        order_by: [desc: st.study_date, asc: st.patient_id, asc: s.series_number, asc: s.id]
      )

    base
    |> maybe_filter_modality(filters["modality"])
    |> maybe_filter_body_part(filters["body_part"])
    |> maybe_filter_institution(filters["institution"])
    |> maybe_filter_date_from(filters["date_from"])
    |> maybe_filter_date_to(filters["date_to"])
    |> maybe_filter_query(filters["q"])
    |> maybe_filter_source(filters["archive_source_id"])
    |> Repo.all()
  end

  def list_series_by_ids(series_ids) when is_list(series_ids) do
    from(s in Series,
      where: s.id in ^series_ids,
      preload: [:study]
    )
    |> Repo.all()
  end

  def get_study_with_series!(id) do
    Study
    |> preload(:series)
    |> Repo.get!(id)
  end

  def list_instances_for_series(series_id) do
    from(i in Instance,
      where: i.series_id == ^series_id,
      preload: [:archive_source, :series, :study],
      order_by: [asc: i.instance_number, asc: i.id]
    )
    |> Repo.all()
  end

  # Private helpers

  defp upsert_study!(meta) do
    now = DateTime.utc_now(:second)

    attrs = %{
      study_instance_uid: meta.study_instance_uid,
      patient_id: meta.patient_id,
      patient_name: meta.patient_name,
      patient_sex: meta.patient_sex,
      patient_birth_date: meta.patient_birth_date,
      study_date: meta.study_date,
      study_time: meta.study_time,
      study_description: meta.study_description,
      accession_number: meta.accession_number,
      institution_name: meta.institution_name,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(
      Study,
      [attrs],
      on_conflict:
        {:replace,
         [
           :patient_id,
           :patient_name,
           :patient_sex,
           :patient_birth_date,
           :study_date,
           :study_time,
           :study_description,
           :accession_number,
           :institution_name,
           :updated_at
         ]},
      conflict_target: :study_instance_uid
    )

    Repo.get_by!(Study, study_instance_uid: meta.study_instance_uid)
  end

  defp upsert_series!(study, meta) do
    now = DateTime.utc_now(:second)

    attrs = %{
      series_instance_uid: meta.series_instance_uid,
      study_id: study.id,
      modality: meta.modality,
      body_part_examined: meta.body_part_examined,
      series_description: meta.series_description,
      series_number: meta.series_number,
      protocol_name: meta.protocol_name,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(
      Series,
      [attrs],
      on_conflict:
        {:replace,
         [
           :modality,
           :body_part_examined,
           :series_description,
           :series_number,
           :protocol_name,
           :updated_at
         ]},
      conflict_target: :series_instance_uid
    )

    Repo.get_by!(Series, series_instance_uid: meta.series_instance_uid)
  end

  defp upsert_instance!(archive_source_id, study, series, meta) do
    now = DateTime.utc_now(:second)

    attrs = %{
      sop_instance_uid: meta.sop_instance_uid,
      series_id: series.id,
      study_id: study.id,
      archive_source_id: archive_source_id,
      file_path: meta.file_path,
      sop_class_uid: meta.sop_class_uid,
      transfer_syntax_uid: meta.transfer_syntax_uid,
      instance_number: meta.instance_number,
      rows: meta.rows,
      columns: meta.columns,
      number_of_frames: meta.number_of_frames || 1,
      file_size_bytes: meta.file_size_bytes || 0,
      metadata_json: meta.metadata_json,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(
      Instance,
      [attrs],
      on_conflict:
        {:replace,
         [
           :series_id,
           :study_id,
           :archive_source_id,
           :file_path,
           :sop_class_uid,
           :transfer_syntax_uid,
           :instance_number,
           :rows,
           :columns,
           :number_of_frames,
           :file_size_bytes,
           :metadata_json,
           :updated_at
         ]},
      conflict_target: :sop_instance_uid
    )

    Repo.get_by!(Instance, sop_instance_uid: meta.sop_instance_uid)
  end

  defp normalize_filters(filters) when is_map(filters) do
    Map.new(filters, fn {k, v} ->
      val =
        case v do
          s when is_binary(s) -> String.trim(s)
          other -> other
        end

      {to_string(k), val}
    end)
  end

  defp maybe_filter_modality(query, nil), do: query
  defp maybe_filter_modality(query, ""), do: query
  defp maybe_filter_modality(query, mod), do: where(query, [s], s.modality == ^mod)

  defp maybe_filter_body_part(query, nil), do: query
  defp maybe_filter_body_part(query, ""), do: query

  defp maybe_filter_body_part(query, bp) do
    where(query, [s], s.body_part_examined == ^bp)
  end

  defp maybe_filter_institution(query, nil), do: query
  defp maybe_filter_institution(query, ""), do: query

  defp maybe_filter_institution(query, inst) do
    where(query, [_s, st], st.institution_name == ^inst)
  end

  defp maybe_filter_date_from(query, nil), do: query
  defp maybe_filter_date_from(query, ""), do: query

  defp maybe_filter_date_from(query, date_from) do
    normalized = String.replace(date_from, "-", "")
    where(query, [_s, st], st.study_date >= ^normalized)
  end

  defp maybe_filter_date_to(query, nil), do: query
  defp maybe_filter_date_to(query, ""), do: query

  defp maybe_filter_date_to(query, date_to) do
    normalized = String.replace(date_to, "-", "")
    where(query, [_s, st], st.study_date <= ^normalized)
  end

  defp maybe_filter_query(query, nil), do: query
  defp maybe_filter_query(query, ""), do: query

  defp maybe_filter_query(query, term) do
    pattern = "%#{term}%"

    where(
      query,
      [s, st],
      like(st.patient_id, ^pattern) or
        like(st.patient_name, ^pattern) or
        like(st.study_description, ^pattern) or
        like(st.study_instance_uid, ^pattern) or
        like(st.accession_number, ^pattern) or
        like(st.institution_name, ^pattern) or
        like(s.series_description, ^pattern) or
        like(s.series_instance_uid, ^pattern) or
        like(s.protocol_name, ^pattern) or
        like(s.body_part_examined, ^pattern) or
        like(s.modality, ^pattern)
    )
  end

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, ""), do: query

  defp maybe_filter_source(query, source_id) do
    case Integer.parse(to_string(source_id)) do
      {id, ""} ->
        series_ids_subquery =
          from(i in Instance,
            where: i.archive_source_id == ^id,
            select: i.series_id
          )

        where(query, [s], s.id in subquery(series_ids_subquery))

      _ ->
        query
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
