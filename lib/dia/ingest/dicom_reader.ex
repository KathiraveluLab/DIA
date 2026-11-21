defmodule Dia.Ingest.DicomReader do
  @moduledoc """
  Pure-Elixir DICOM Part 10 metadata extraction, de-identification, and path-boundary checks.
  """

  alias Dicom.{DataSet, DeIdentification, Json, PixelData, Tag, UID}

  @pixel_data_tag {0x7FE0, 0x0010}

  @doc """
  Checks that `file_path` resolves strictly within `root_path` after canonical expansion.
  """
  @spec safe_path?(Path.t(), Path.t()) :: boolean()
  def safe_path?(file_path, root_path) when is_binary(file_path) and is_binary(root_path) do
    expanded_file = Path.expand(file_path)
    expanded_root = Path.expand(root_path)

    expanded_file == expanded_root or
      String.starts_with?(expanded_file, String.trim_trailing(expanded_root, "/") <> "/")
  end

  def safe_path?(_, _), do: false

  @doc """
  Streams a DICOM Part 10 file and extracts header metadata without storing pixel payloads.
  """
  @spec read_metadata(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_metadata(file_path) when is_binary(file_path) do
    with {:ok, %File.Stat{size: size, type: :regular}} <- File.stat(file_path),
         {:ok, ds} <- parse_header_only(file_path),
         {:ok, study_uid} <- require_uid(ds, Tag.study_instance_uid(), :missing_study_uid),
         {:ok, series_uid} <- require_uid(ds, Tag.series_instance_uid(), :missing_series_uid),
         {:ok, sop_uid} <- require_uid(ds, Tag.sop_instance_uid(), :missing_sop_uid) do
      clean_ds = DataSet.delete(ds, @pixel_data_tag)
      metadata_map = safe_to_json_map(clean_ds)

      {:ok,
       %{
         file_path: Path.expand(file_path),
         file_size_bytes: size,
         study_instance_uid: study_uid,
         series_instance_uid: series_uid,
         sop_instance_uid: sop_uid,
         sop_class_uid: get_trimmed(ds, Tag.sop_class_uid()),
         transfer_syntax_uid: get_trimmed(ds, {0x0002, 0x0010}) || "1.2.840.10008.1.2.1",
         patient_id: get_trimmed(ds, Tag.patient_id()),
         patient_name: get_trimmed(ds, Tag.patient_name()),
         patient_sex: get_trimmed(ds, {0x0010, 0x0040}),
         patient_birth_date: get_trimmed(ds, {0x0010, 0x0030}),
         study_date: get_trimmed(ds, Tag.study_date()),
         study_time: get_trimmed(ds, Tag.study_time()),
         study_description: get_trimmed(ds, {0x0008, 0x1030}),
         accession_number: get_trimmed(ds, {0x0008, 0x0050}),
         institution_name: get_trimmed(ds, {0x0008, 0x0080}),
         modality: get_trimmed(ds, Tag.modality()) || "OT",
         body_part_examined: get_trimmed(ds, {0x0018, 0x0015}),
         series_description: get_trimmed(ds, {0x0008, 0x103E}),
         series_number: get_trimmed(ds, {0x0020, 0x0011}),
         protocol_name: get_trimmed(ds, {0x0018, 0x1030}),
         instance_number: get_trimmed(ds, {0x0020, 0x0013}),
         rows: get_integer(ds, Tag.rows()),
         columns: get_integer(ds, Tag.columns()),
         number_of_frames: get_integer(ds, Tag.number_of_frames()) || 1,
         metadata_json: Jason.encode!(metadata_map)
       }}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_regular_file}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Reads a full DICOM Part 10 file into a `Dicom.DataSet`, optionally applying PS3.15
  de-identification. When `uid_map` is provided with `remap_uids: true`, Study, Series,
  SOP, and Frame of Reference UIDs are mapped consistently across all instances in a job.
  """
  @spec load_dataset(Path.t(), keyword()) ::
          {:ok, DataSet.t(), map()} | {:error, term()}
  def load_dataset(file_path, opts \\ []) do
    deidentify? = Keyword.get(opts, :deidentify, false)
    retain_uids? = Keyword.get(opts, :retain_uids, true)
    uid_map = Keyword.get(opts, :uid_map, %{})

    with {:ok, ds} <- Dicom.parse_file(file_path) do
      if deidentify? do
        {:ok, cleaned, _local_map} =
          DeIdentification.apply(ds,
            retain_uids: true,
            clean_descriptions: false
          )

        if retain_uids? do
          {:ok, cleaned, uid_map}
        else
          {remapped, updated_map} = remap_uids_consistently(cleaned, uid_map)

          marked =
            remapped
            |> DataSet.put({0x0012, 0x0062}, :CS, "YES")
            |> DataSet.put(
              {0x0012, 0x0063},
              :LO,
              "DIA PS3.15 Basic Profile with Album-Consistent UID Remapping"
            )

          {:ok, marked, updated_map}
        end
      else
        {:ok, ds, uid_map}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Loads a DICOM file and serializes it back to Part 10 binary, applying de-identification
  if requested. When `deidentify: false`, reads raw bytes directly from disk without re-encoding.
  """
  @spec load_part10_binary(Path.t(), keyword()) ::
          {:ok, binary(), map()} | {:error, term()}
  def load_part10_binary(file_path, opts \\ []) do
    if Keyword.get(opts, :deidentify, false) do
      with {:ok, ds, updated_map} <- load_dataset(file_path, opts),
           {:ok, binary} <- Dicom.write(ds) do
        {:ok, binary, updated_map}
      end
    else
      case File.read(file_path) do
        {:ok, binary} -> {:ok, binary, Keyword.get(opts, :uid_map, %{})}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Builds a DICOMweb WADO-RS metadata map (PS3.18 Annex F.2) for an instance, emitting a
  BulkDataURI for pixel data rather than inlining raw image bytes.
  """
  @spec to_wado_metadata(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def to_wado_metadata(file_path, frames_base_url, opts \\ []) do
    with {:ok, ds, _uid_map} <- load_dataset(file_path, Keyword.put(opts, :retain_uids, true)) do
      bulk_uri_fn = fn
        {0x7FE0, 0x0010}, _vr -> frames_base_url
        _tag, _vr -> nil
      end

      {:ok, Json.to_map(ds, bulk_data_uri: bulk_uri_fn)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Extracts one-based frame numbers (per DICOMweb WADO-RS spec) from a local DICOM file.
  """
  @spec extract_frames(Path.t(), [pos_integer()]) :: {:ok, [binary()]} | {:error, term()}
  def extract_frames(file_path, frame_numbers) when is_list(frame_numbers) do
    with {:ok, ds} <- Dicom.parse_file(file_path) do
      Enum.reduce_while(frame_numbers, {:ok, []}, fn one_based_idx, {:ok, acc} ->
        case PixelData.frame(ds, one_based_idx - 1) do
          {:ok, frame_bin} -> {:cont, {:ok, [frame_bin | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, frames} -> {:ok, Enum.reverse(frames)}
        {:error, _} = err -> err
      end
    end
  end

  defp parse_header_only(file_path) do
    events =
      file_path
      |> Dicom.stream_parse_file()
      |> Stream.take_while(fn
        {:pixel_data_start, _, _} -> false
        {:element, %Dicom.DataElement{tag: @pixel_data_tag}} -> false
        _ -> true
      end)

    Dicom.P10.Stream.to_data_set(events)
  end

  defp require_uid(ds, tag, error_atom) do
    case get_trimmed(ds, tag) do
      nil -> {:error, error_atom}
      "" -> {:error, error_atom}
      uid -> {:ok, uid}
    end
  end

  defp get_trimmed(ds, tag) do
    case DataSet.get(ds, tag) do
      val when is_binary(val) ->
        val
        |> String.trim_trailing(<<0>>)
        |> String.trim()
        |> case do
          "" -> nil
          cleaned -> cleaned
        end

      val when is_integer(val) ->
        Integer.to_string(val)

      _ ->
        nil
    end
  end

  defp get_integer(ds, tag) do
    case DataSet.decoded_value(ds, tag) do
      val when is_integer(val) ->
        val

      val when is_binary(val) ->
        case Integer.parse(String.trim(val)) do
          {int, ""} -> int
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp safe_to_json_map(ds) do
    Json.to_map(ds, bulk_data_uri: fn _tag, _vr -> nil end)
  rescue
    _ -> %{}
  end

  @uid_tags_to_remap [
    {0x0002, 0x0003},
    {0x0008, 0x0018},
    {0x0020, 0x000D},
    {0x0020, 0x000E},
    {0x0020, 0x0052}
  ]

  defp remap_uids_consistently(ds, uid_map) do
    Enum.reduce(@uid_tags_to_remap, {ds, uid_map}, fn tag, {acc_ds, acc_map} ->
      case get_trimmed(acc_ds, tag) do
        nil ->
          {acc_ds, acc_map}

        orig_uid ->
          {mapped_uid, next_map} =
            case Map.get(acc_map, orig_uid) do
              nil ->
                generated = UID.generate()
                {generated, Map.put(acc_map, orig_uid, generated)}

              existing ->
                {existing, acc_map}
            end

          {DataSet.put(acc_ds, tag, :UI, mapped_uid), next_map}
      end
    end)
  end
end
