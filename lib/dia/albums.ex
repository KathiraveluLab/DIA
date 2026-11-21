defmodule Dia.Albums do
  @moduledoc """
  Manages zero-copy DICOM albums, cohort manifest exports, and Mode B capability-scoped
  virtual DICOMweb share links for OHIF Viewer integration.
  """

  import Ecto.Query

  alias Dia.Repo
  alias Dia.Albums.{Album, AlbumSeries, ShareLink}
  alias Dia.Catalog.{Instance, Series, Study}
  alias Dia.Ingest.DicomReader

  # Albums

  def list_albums do
    Album
    |> preload([:share_links, :kheops_publish_jobs, series: :study])
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  def get_album!(id) do
    Album
    |> preload(
      series: :study,
      share_links: ^from(l in ShareLink, order_by: [desc: l.inserted_at]),
      kheops_publish_jobs: ^from(j in Dia.Kheops.PublishJob, order_by: [desc: j.inserted_at])
    )
    |> Repo.get!(id)
  end

  def change_album(%Album{} = album, attrs \\ %{}) do
    Album.changeset(album, attrs)
  end

  def create_album(attrs, series_ids \\ []) when is_list(series_ids) do
    Repo.transaction(fn ->
      case %Album{} |> Album.changeset(attrs) |> Repo.insert() do
        {:ok, album} ->
          attach_series(album.id, series_ids)
          get_album!(album.id)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def add_series_to_album(%Album{} = album, series_ids) when is_list(series_ids) do
    attach_series(album.id, series_ids)
    {:ok, get_album!(album.id)}
  end

  def remove_series_from_album(%Album{} = album, series_id) do
    from(as in AlbumSeries, where: as.album_id == ^album.id and as.series_id == ^series_id)
    |> Repo.delete_all()

    {:ok, get_album!(album.id)}
  end

  def delete_album(%Album{} = album) do
    Repo.delete(album)
  end

  def album_summary(%Album{series: series}) when is_list(series) do
    study_ids =
      series
      |> Enum.map(& &1.study_id)
      |> Enum.uniq()

    instance_count = Enum.reduce(series, 0, fn s, acc -> acc + (s.instance_count || 0) end)

    modalities =
      series
      |> Enum.map(& &1.modality)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      study_count: length(study_ids),
      series_count: length(series),
      instance_count: instance_count,
      modalities: modalities
    }
  end

  def list_album_instances(%Album{id: album_id}) do
    from(i in Instance,
      join: as in AlbumSeries,
      on: as.series_id == i.series_id,
      where: as.album_id == ^album_id,
      preload: [:archive_source, :series, :study],
      order_by: [asc: i.study_id, asc: i.series_id, asc: i.instance_number, asc: i.id]
    )
    |> Repo.all()
  end

  # Cohort Manifest Export

  def export_manifest_map(%Album{} = album) do
    instances = list_album_instances(album)

    query_filter =
      case album.query_filter_json do
        json when is_binary(json) and json != "" ->
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    %{
      album_id: album.id,
      name: album.name,
      description: album.description,
      generated_at: DateTime.utc_now(:second) |> DateTime.to_iso8601(),
      query_filter: query_filter,
      summary: %{
        studies: instances |> Enum.map(& &1.study.study_instance_uid) |> Enum.uniq() |> length(),
        series: instances |> Enum.map(& &1.series.series_instance_uid) |> Enum.uniq() |> length(),
        instances: length(instances),
        total_bytes: Enum.reduce(instances, 0, fn i, acc -> acc + (i.file_size_bytes || 0) end)
      },
      instances:
        Enum.map(instances, fn inst ->
          %{
            study_instance_uid: inst.study.study_instance_uid,
            series_instance_uid: inst.series.series_instance_uid,
            sop_instance_uid: inst.sop_instance_uid,
            modality: inst.series.modality,
            body_part_examined: inst.series.body_part_examined,
            study_date: inst.study.study_date,
            file_size_bytes: inst.file_size_bytes
          }
        end)
    }
  end

  def export_manifest_csv(%Album{} = album) do
    instances = list_album_instances(album)

    header =
      "study_instance_uid,series_instance_uid,sop_instance_uid,modality,body_part_examined,study_date,file_size_bytes\n"

    rows =
      Enum.map(instances, fn inst ->
        [
          inst.study.study_instance_uid,
          inst.series.series_instance_uid,
          inst.sop_instance_uid,
          inst.series.modality || "",
          inst.series.body_part_examined || "",
          inst.study.study_date || "",
          to_string(inst.file_size_bytes || 0)
        ]
        |> Enum.map(&csv_escape/1)
        |> Enum.join(",")
      end)

    header <> Enum.join(rows, "\n") <> if(rows != [], do: "\n", else: "")
  end

  # Mode B: Share Links & Album-Scoped DICOMweb Queries

  def change_share_link(%ShareLink{} = share_link, attrs \\ %{}) do
    ShareLink.changeset(share_link, attrs)
  end

  def create_share_link(%Album{} = album, attrs) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    %ShareLink{album_id: album.id, token: token}
    |> ShareLink.changeset(attrs)
    |> Repo.insert()
  end

  def revoke_share_link(%ShareLink{} = share_link) do
    share_link
    |> Ecto.Changeset.change(revoked_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  def get_share_link!(id), do: Repo.get!(ShareLink, id)

  def resolve_active_share_link(token) when is_binary(token) and token != "" do
    case Repo.get_by(ShareLink, token: token) |> Repo.preload(:album) do
      nil ->
        {:error, :not_found}

      %ShareLink{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :revoked}

      %ShareLink{} = link ->
        if ShareLink.active?(link) do
          now = DateTime.utc_now(:second)

          from(l in ShareLink, where: l.id == ^link.id)
          |> Repo.update_all(inc: [access_count: 1], set: [last_accessed_at: now])

          {:ok, %{link | access_count: link.access_count + 1, last_accessed_at: now}}
        else
          {:error, :expired}
        end
    end
  end

  def resolve_active_share_link(_), do: {:error, :not_found}

  def qido_studies(album_id, params \\ %{}) do
    query =
      from(st in Study,
        join: s in Series,
        on: s.study_id == st.id,
        join: as in AlbumSeries,
        on: as.series_id == s.id,
        where: as.album_id == ^album_id,
        distinct: true,
        order_by: [desc: st.study_date, asc: st.study_instance_uid]
      )

    query
    |> maybe_qido_match(params["StudyInstanceUID"] || params["0020000D"], fn q, v ->
      where(q, [st], st.study_instance_uid == ^v)
    end)
    |> maybe_qido_match(params["PatientID"] || params["00100020"], fn q, v ->
      where(q, [st], like(st.patient_id, ^wildcard_to_like(v)))
    end)
    |> maybe_qido_match(params["PatientName"] || params["00100010"], fn q, v ->
      where(q, [st], like(st.patient_name, ^wildcard_to_like(v)))
    end)
    |> maybe_qido_match(params["ModalitiesInStudy"] || params["00080061"], fn q, v ->
      where(q, [_st, s], s.modality == ^v)
    end)
    |> maybe_qido_match(params["StudyDescription"] || params["00081030"], fn q, v ->
      where(q, [st], like(st.study_description, ^wildcard_to_like(v)))
    end)
    |> Repo.all()
  end

  def qido_series(album_id, study_uid, params \\ %{}) do
    query =
      from(s in Series,
        join: st in Study,
        on: st.id == s.study_id,
        join: as in AlbumSeries,
        on: as.series_id == s.id,
        where: as.album_id == ^album_id and st.study_instance_uid == ^study_uid,
        preload: [study: st],
        order_by: [asc: s.series_number, asc: s.series_instance_uid]
      )

    query
    |> maybe_qido_match(params["SeriesInstanceUID"] || params["0020000E"], fn q, v ->
      where(q, [s], s.series_instance_uid == ^v)
    end)
    |> maybe_qido_match(params["Modality"] || params["00080060"], fn q, v ->
      where(q, [s], s.modality == ^v)
    end)
    |> maybe_qido_match(params["SeriesDescription"] || params["0008103E"], fn q, v ->
      where(q, [s], like(s.series_description, ^wildcard_to_like(v)))
    end)
    |> Repo.all()
  end

  def qido_instances(album_id, study_uid, series_uid) do
    from(i in Instance,
      join: s in Series,
      on: s.id == i.series_id,
      join: st in Study,
      on: st.id == s.study_id,
      join: as in AlbumSeries,
      on: as.series_id == s.id,
      where:
        as.album_id == ^album_id and
          st.study_instance_uid == ^study_uid and
          s.series_instance_uid == ^series_uid,
      preload: [:archive_source, :series, :study],
      order_by: [asc: i.instance_number, asc: i.sop_instance_uid]
    )
    |> Repo.all()
  end

  def get_scoped_instance(album_id, study_uid, series_uid, sop_uid) do
    instance =
      from(i in Instance,
        join: s in Series,
        on: s.id == i.series_id,
        join: st in Study,
        on: st.id == s.study_id,
        join: as in AlbumSeries,
        on: as.series_id == s.id,
        where:
          as.album_id == ^album_id and
            st.study_instance_uid == ^study_uid and
            s.series_instance_uid == ^series_uid and
            i.sop_instance_uid == ^sop_uid,
        preload: [:archive_source, :series, :study]
      )
      |> Repo.one()

    case instance do
      nil ->
        {:error, :not_found}

      %Instance{file_path: path, archive_source: %{root_path: root}} = inst ->
        if DicomReader.safe_path?(path, root) and File.regular?(path) do
          {:ok, inst}
        else
          {:error, :file_unavailable}
        end
    end
  end

  def album_study_counts(album_id, study_id) do
    series_rows =
      from(s in Series,
        join: as in AlbumSeries,
        on: as.series_id == s.id,
        where: as.album_id == ^album_id and s.study_id == ^study_id,
        select: {s.modality, s.instance_count}
      )
      |> Repo.all()

    %{
      series_count: length(series_rows),
      instance_count: Enum.reduce(series_rows, 0, fn {_, c}, acc -> acc + (c || 0) end),
      modalities:
        series_rows
        |> Enum.map(fn {m, _} -> m end)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  # Private helpers

  defp attach_series(_album_id, []), do: :ok

  defp attach_series(album_id, series_ids) do
    now = DateTime.utc_now(:second)

    entries =
      series_ids
      |> Enum.uniq()
      |> Enum.map(fn sid ->
        %{album_id: album_id, series_id: sid, inserted_at: now, updated_at: now}
      end)

    Repo.insert_all(AlbumSeries, entries, on_conflict: :nothing)
    :ok
  end

  defp maybe_qido_match(query, nil, _fun), do: query
  defp maybe_qido_match(query, "", _fun), do: query
  defp maybe_qido_match(query, value, fun), do: fun.(query, String.trim(value))

  defp wildcard_to_like(value) do
    if String.contains?(value, "*") do
      String.replace(value, "*", "%")
    else
      "%#{value}%"
    end
  end

  defp csv_escape(val) do
    if String.contains?(val, [",", "\"", "\n"]) do
      "\"" <> String.replace(val, "\"", "\"\"") <> "\""
    else
      val
    end
  end
end
