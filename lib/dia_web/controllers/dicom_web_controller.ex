defmodule DiaWeb.DicomWebController do
  @moduledoc """
  Mode B standalone virtual DICOMweb server (QIDO-RS and WADO-RS) scoped strictly
  by capability share tokens for zero-copy viewing in OHIF Viewer.
  """
  use DiaWeb, :controller

  alias Dia.Albums
  alias Dia.Albums.ShareLink
  alias Dia.Ingest.DicomReader

  def options(conn, _params) do
    send_resp(conn, :no_content, "")
  end

  def qido_studies(conn, %{"token" => token} = params) do
    with_active_link(conn, token, fn %ShareLink{album_id: album_id, deidentify: deidentify?} ->
      studies = Albums.qido_studies(album_id, params)

      payload =
        Enum.map(studies, fn study ->
          counts = Albums.album_study_counts(album_id, study.id)
          encode_qido_study(study, counts, deidentify?)
        end)

      send_dicom_json(conn, payload)
    end)
  end

  def qido_series(conn, %{"token" => token, "study_uid" => study_uid} = params) do
    with_active_link(conn, token, fn %ShareLink{album_id: album_id} ->
      series_list = Albums.qido_series(album_id, study_uid, params)
      payload = Enum.map(series_list, &encode_qido_series(&1, study_uid))
      send_dicom_json(conn, payload)
    end)
  end

  def qido_instances(conn, %{
        "token" => token,
        "study_uid" => study_uid,
        "series_uid" => series_uid
      }) do
    with_active_link(conn, token, fn %ShareLink{album_id: album_id} ->
      instances = Albums.qido_instances(album_id, study_uid, series_uid)
      payload = Enum.map(instances, &encode_qido_instance(&1, study_uid, series_uid))
      send_dicom_json(conn, payload)
    end)
  end

  def wado_series_metadata(conn, %{
        "token" => token,
        "study_uid" => study_uid,
        "series_uid" => series_uid
      }) do
    with_active_link(conn, token, fn %ShareLink{album_id: album_id, deidentify: deidentify?} ->
      instances = Albums.qido_instances(album_id, study_uid, series_uid)

      if instances == [] do
        send_json_error(conn, :not_found, "No series instances found in this album")
      else
        base_url = dicomweb_root_url(conn, token)

        metadata_list =
          Enum.reduce(instances, [], fn inst, acc ->
            root = inst.archive_source.root_path

            if DicomReader.safe_path?(inst.file_path, root) and File.regular?(inst.file_path) do
              frames_url =
                "#{base_url}/studies/#{study_uid}/series/#{series_uid}/instances/#{inst.sop_instance_uid}/frames/1"

              case DicomReader.to_wado_metadata(inst.file_path, frames_url,
                     deidentify: deidentify?
                   ) do
                {:ok, map} -> [map | acc]
                {:error, _} -> acc
              end
            else
              acc
            end
          end)
          |> Enum.reverse()

        send_dicom_json(conn, metadata_list)
      end
    end)
  end

  def wado_instance(conn, %{
        "token" => token,
        "study_uid" => study_uid,
        "series_uid" => series_uid,
        "sop_uid" => sop_uid
      }) do
    with_active_link(conn, token, fn %ShareLink{album_id: album_id, deidentify: deidentify?} ->
      case Albums.get_scoped_instance(album_id, study_uid, series_uid, sop_uid) do
        {:ok, inst} ->
          case DicomReader.load_part10_binary(inst.file_path,
                 deidentify: deidentify?,
                 retain_uids: true
               ) do
            {:ok, binary, _uid_map} ->
              send_wado_dicom(conn, binary)

            {:error, _reason} ->
              send_json_error(conn, :internal_server_error, "Unable to read DICOM instance")
          end

        {:error, :not_found} ->
          send_json_error(conn, :not_found, "Instance not found in album scope")

        {:error, :file_unavailable} ->
          send_json_error(conn, :not_found, "Local DICOM file is unavailable")
      end
    end)
  end

  def wado_frames(conn, %{
        "token" => token,
        "study_uid" => study_uid,
        "series_uid" => series_uid,
        "sop_uid" => sop_uid,
        "frames" => frames_param
      }) do
    with_active_link(conn, token, fn %ShareLink{album_id: album_id} ->
      with {:ok, frame_numbers} <- parse_frame_numbers(frames_param),
           {:ok, inst} <- Albums.get_scoped_instance(album_id, study_uid, series_uid, sop_uid),
           {:ok, frame_binaries} <- DicomReader.extract_frames(inst.file_path, frame_numbers) do
        send_multipart_frames(conn, frame_binaries)
      else
        {:error, :invalid_frames} ->
          send_json_error(conn, :bad_request, "Invalid frame list requested")

        {:error, :not_found} ->
          send_json_error(conn, :not_found, "Instance not found in album scope")

        {:error, :file_unavailable} ->
          send_json_error(conn, :not_found, "Local DICOM file is unavailable")

        {:error, _reason} ->
          send_json_error(conn, :not_found, "Requested frames could not be extracted")
      end
    end)
  end

  def ohif_config(conn, %{"token" => token}) do
    with_active_link(conn, token, fn %ShareLink{album: album} ->
      root = dicomweb_root_url(conn, token)

      config = %{
        routerBasename: "/",
        showStudyList: true,
        defaultDataSourceName: "dia_album_#{album.id}",
        dataSources: [
          %{
            namespace: "@ohif/extension-default.dataSourcesModule.dicomweb",
            sourceName: "dia_album_#{album.id}",
            configuration: %{
              friendlyName: "DIA Album: #{album.name}",
              name: "dia_album_#{album.id}",
              wadoUriRoot: root,
              qidoRoot: root,
              wadoRoot: root,
              qidoSupportsIncludeField: false,
              supportsReject: false,
              imageRendering: "wadors",
              thumbnailRendering: "wadors",
              enableStudyLazyLoad: true,
              supportsFuzzyMatching: true,
              supportsWildcard: true,
              omitQuotationForMultipartRequest: true
            }
          }
        ]
      }

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(:ok, Jason.encode!(config, pretty: true))
    end)
  end

  # Private helpers

  defp with_active_link(conn, token, fun) do
    case Albums.resolve_active_share_link(token) do
      {:ok, share_link} ->
        fun.(share_link)

      {:error, :not_found} ->
        send_json_error(conn, :not_found, "Album share token not found")

      {:error, :revoked} ->
        send_json_error(conn, :unauthorized, "Album share link has been revoked")

      {:error, :expired} ->
        send_json_error(conn, :unauthorized, "Album share link has expired")
    end
  end

  defp send_dicom_json(conn, payload) do
    conn
    |> put_resp_content_type("application/dicom+json")
    |> send_resp(:ok, Jason.encode!(payload))
  end

  defp send_json_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
  end

  defp send_wado_dicom(conn, binary) do
    accept = conn |> get_req_header("accept") |> Enum.join(", ")

    if String.contains?(accept, "application/dicom") and not String.contains?(accept, "multipart") do
      conn
      |> put_resp_content_type("application/dicom")
      |> send_resp(:ok, binary)
    else
      boundary = "dia_wado_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

      body =
        IO.iodata_to_binary([
          "--",
          boundary,
          "\r\nContent-Type: application/dicom\r\n\r\n",
          binary,
          "\r\n--",
          boundary,
          "--\r\n"
        ])

      conn
      |> put_resp_header(
        "content-type",
        ~s(multipart/related; type="application/dicom"; boundary="#{boundary}")
      )
      |> send_resp(:ok, body)
    end
  end

  defp send_multipart_frames(conn, frame_binaries) do
    boundary = "dia_frames_" <> Base.encode16(:crypto.strong_rand_bytes(10), case: :lower)

    parts =
      Enum.map(frame_binaries, fn bin ->
        [
          "--",
          boundary,
          "\r\nContent-Type: application/octet-stream\r\n\r\n",
          bin,
          "\r\n"
        ]
      end)

    body = IO.iodata_to_binary([parts, "--", boundary, "--\r\n"])

    conn
    |> put_resp_header(
      "content-type",
      ~s(multipart/related; type="application/octet-stream"; boundary="#{boundary}")
    )
    |> send_resp(:ok, body)
  end

  defp parse_frame_numbers(frames_param) when is_binary(frames_param) do
    parsed =
      frames_param
      |> String.split(",", trim: true)
      |> Enum.map(&Integer.parse/1)

    if parsed != [] and Enum.all?(parsed, fn {n, rem} -> rem == "" and n > 0 end) do
      {:ok, Enum.map(parsed, fn {n, ""} -> n end)}
    else
      {:error, :invalid_frames}
    end
  end

  defp parse_frame_numbers(_), do: {:error, :invalid_frames}

  defp dicomweb_root_url(conn, token) do
    scheme = Atom.to_string(conn.scheme)

    port_suffix =
      case {conn.scheme, conn.port} do
        {:http, 80} -> ""
        {:https, 443} -> ""
        {_, port} -> ":#{port}"
      end

    "#{scheme}://#{conn.host}#{port_suffix}/dicomweb/albums/#{token}"
  end

  defp encode_qido_study(study, counts, deidentify?) do
    patient_name = if deidentify?, do: "ANONYMOUS", else: study.patient_name
    patient_id = if deidentify?, do: "ANON-#{study.id}", else: study.patient_id
    birth_date = if deidentify?, do: nil, else: study.patient_birth_date
    institution = if deidentify?, do: nil, else: study.institution_name
    accession = if deidentify?, do: nil, else: study.accession_number

    %{}
    |> put_tag("0020000D", "UI", study.study_instance_uid)
    |> put_tag("00080020", "DA", study.study_date)
    |> put_tag("00080030", "TM", study.study_time)
    |> put_tag("00080050", "SH", accession)
    |> put_tag("00080061", "CS", counts.modalities)
    |> put_tag("00080080", "LO", institution)
    |> put_tag("00081030", "LO", study.study_description)
    |> put_pn_tag("00100010", patient_name)
    |> put_tag("00100020", "LO", patient_id)
    |> put_tag("00100030", "DA", birth_date)
    |> put_tag("00100040", "CS", study.patient_sex)
    |> put_tag("00201206", "IS", Integer.to_string(counts.series_count))
    |> put_tag("00201208", "IS", Integer.to_string(counts.instance_count))
  end

  defp encode_qido_series(series, study_uid) do
    %{}
    |> put_tag("0020000D", "UI", study_uid)
    |> put_tag("0020000E", "UI", series.series_instance_uid)
    |> put_tag("00080060", "CS", series.modality)
    |> put_tag("00180015", "CS", series.body_part_examined)
    |> put_tag("0008103E", "LO", series.series_description)
    |> put_tag("00200011", "IS", series.series_number)
    |> put_tag("00201209", "IS", Integer.to_string(series.instance_count || 0))
  end

  defp encode_qido_instance(inst, study_uid, series_uid) do
    %{}
    |> put_tag("0020000D", "UI", study_uid)
    |> put_tag("0020000E", "UI", series_uid)
    |> put_tag("00080018", "UI", inst.sop_instance_uid)
    |> put_tag("00080016", "UI", inst.sop_class_uid)
    |> put_tag("00200013", "IS", inst.instance_number)
    |> put_numeric_tag("00280010", "US", inst.rows)
    |> put_numeric_tag("00280011", "US", inst.columns)
    |> put_tag("00280008", "IS", Integer.to_string(inst.number_of_frames || 1))
  end

  defp put_tag(map, _tag, _vr, nil), do: map
  defp put_tag(map, _tag, _vr, ""), do: map
  defp put_tag(map, _tag, _vr, []), do: map

  defp put_tag(map, tag, vr, values) when is_list(values) do
    Map.put(map, tag, %{"vr" => vr, "Value" => values})
  end

  defp put_tag(map, tag, vr, value) do
    Map.put(map, tag, %{"vr" => vr, "Value" => [value]})
  end

  defp put_numeric_tag(map, _tag, _vr, nil), do: map

  defp put_numeric_tag(map, tag, vr, value) when is_integer(value) do
    Map.put(map, tag, %{"vr" => vr, "Value" => [value]})
  end

  defp put_pn_tag(map, _tag, nil), do: map
  defp put_pn_tag(map, _tag, ""), do: map

  defp put_pn_tag(map, tag, name) do
    Map.put(map, tag, %{"vr" => "PN", "Value" => [%{"Alphabetic" => name}]})
  end
end
