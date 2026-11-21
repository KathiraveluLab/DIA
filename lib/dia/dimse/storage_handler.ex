defmodule Dia.Dimse.StorageHandler do
  @moduledoc """
  Pure-Elixir DIMSE Storage SCP handler accepting C-ECHO and C-STORE pushes (including
  PACS C-MOVE sub-operations), writing standard Part 10 DICOM files into the active
  archive directory, and indexing them immediately into DIA's SQLite catalog.
  """

  @behaviour Dimse.Handler

  alias Dia.Catalog
  alias Dia.Dimse.Receiver
  alias Dia.Ingest.DicomReader
  alias Dicom.DataSet

  @explicit_vr_le "1.2.840.10008.1.2.1"

  @supported_sop_classes [
    "1.2.840.10008.1.1",
    "1.2.840.10008.5.1.4.1.1.2",
    "1.2.840.10008.5.1.4.1.1.2.1",
    "1.2.840.10008.5.1.4.1.1.4",
    "1.2.840.10008.5.1.4.1.1.4.1",
    "1.2.840.10008.5.1.4.1.1.1",
    "1.2.840.10008.5.1.4.1.1.1.1",
    "1.2.840.10008.5.1.4.1.1.6.1",
    "1.2.840.10008.5.1.4.1.1.7",
    "1.2.840.10008.5.1.4.1.1.128",
    "1.2.840.10008.5.1.4.1.1.481.3"
  ]

  @impl true
  def supported_abstract_syntaxes, do: @supported_sop_classes

  @impl true
  def handle_echo(_command, _state), do: {:ok, 0x0000}

  @impl true
  def handle_store(command, data_set_binary, state) when is_binary(data_set_binary) do
    case Receiver.active_target() do
      {:ok, %{archive_source_id: source_id, root_path: root_path}} ->
        ts_uid = state.current_transfer_syntax_uid || "1.2.840.10008.1.2"
        sop_class = command[{0x0000, 0x0002}] || state.current_abstract_syntax_uid
        sop_uid = command[{0x0000, 0x1000}] || Dicom.UID.generate()

        with {:ok, ds} <- Dicom.parse_data_set(data_set_binary, ts_uid),
             p10_ds <- attach_file_meta(ds, sop_class, sop_uid),
             target_path <- build_target_path(root_path, p10_ds, sop_uid),
             true <- DicomReader.safe_path?(target_path, root_path),
             :ok <- File.mkdir_p(Path.dirname(target_path)),
             :ok <- Dicom.write_file(p10_ds, target_path),
             {:ok, meta} <- DicomReader.read_metadata(target_path),
             {:ok, _} <- Catalog.upsert_dicom_metadata(source_id, meta),
             :ok <- Catalog.refresh_aggregates() do
          Receiver.record_received(sop_uid)
          {:ok, 0x0000}
        else
          _ ->
            {:error, 0xC000, "Failed to persist and index incoming C-STORE instance"}
        end

      :error ->
        {:error, 0xC000, "No active DIA archive target configured for DIMSE SCP"}
    end
  end

  @impl true
  def handle_find(_command, _query, _state), do: {:ok, []}

  @impl true
  def handle_move(_command, _query, _state), do: {:ok, []}

  @impl true
  def handle_get(_command, _query, _state), do: {:ok, []}

  defp attach_file_meta(ds, sop_class, sop_uid) do
    resolved_sop_class =
      sop_class ||
        DataSet.get(ds, {0x0008, 0x0016}) ||
        "1.2.840.10008.5.1.4.1.1.7"

    ds
    |> DataSet.put({0x0002, 0x0002}, :UI, clean_uid(resolved_sop_class))
    |> DataSet.put({0x0002, 0x0003}, :UI, clean_uid(sop_uid))
    |> DataSet.put({0x0002, 0x0010}, :UI, @explicit_vr_le)
  end

  defp build_target_path(root_path, ds, sop_uid) do
    study_uid = sanitize_segment(DataSet.get(ds, {0x0020, 0x000D}) || "unknown_study")
    series_uid = sanitize_segment(DataSet.get(ds, {0x0020, 0x000E}) || "unknown_series")
    sop_seg = sanitize_segment(sop_uid)

    Path.join([root_path, "dimse_incoming", study_uid, series_uid, "#{sop_seg}.dcm"])
  end

  defp clean_uid(uid) when is_binary(uid), do: uid |> String.trim_trailing(<<0>>) |> String.trim()
  defp clean_uid(_), do: Dicom.UID.generate()

  defp sanitize_segment(val) do
    val
    |> clean_uid()
    |> String.replace(~r/[^a-zA-Z0-9._-]/, "_")
  end
end
