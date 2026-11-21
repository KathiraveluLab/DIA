defmodule Dia.Ingest.Scanner do
  @moduledoc """
  Concurrent, fault-isolated local DICOM directory scanner backed by `Task.async_stream`.
  """

  alias Dia.Catalog
  alias Dia.Catalog.ArchiveSource
  alias Dia.Ingest.DicomReader

  @pubsub Dia.PubSub
  @topic "ingest:updates"
  @dicom_extensions MapSet.new([".dcm", ".dicom", ""])

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Launches a supervised asynchronous scan for an archive source.
  """
  def start_scan(archive_source_id) do
    Task.Supervisor.start_child(Dia.TaskSupervisor, fn ->
      scan_sync(archive_source_id)
    end)
  end

  @doc """
  Synchronously scans all candidate DICOM files within the archive source's `root_path`.
  Each file is parsed concurrently inside an isolated worker task; malformed files are
  quarantined in `ingest_errors` without interrupting the scan.
  """
  def scan_sync(archive_source_id) do
    source = Catalog.get_archive_source!(archive_source_id)

    if File.dir?(source.root_path) do
      do_scan(source)
    else
      {:ok, updated} =
        Catalog.update_archive_source_status(source, %{
          status: "error",
          last_error: "Directory not found: #{source.root_path}",
          last_scanned_at: DateTime.utc_now(:second)
        })

      broadcast({:scan_completed, updated})
      {:error, :directory_not_found}
    end
  end

  defp do_scan(%ArchiveSource{} = source) do
    Catalog.clear_ingest_errors(source.id)
    candidates = discover_candidate_files(source.root_path)
    total = length(candidates)

    {:ok, source} =
      Catalog.update_archive_source_status(source, %{
        status: "scanning",
        files_discovered: total,
        files_indexed: 0,
        files_quarantined: 0,
        last_error: nil
      })

    broadcast({:scan_started, source})

    concurrency = max(1, System.schedulers_online())

    {indexed, quarantined} =
      candidates
      |> Task.async_stream(
        fn path -> parse_isolated(path) end,
        max_concurrency: concurrency,
        timeout: :infinity,
        ordered: false
      )
      |> Enum.reduce({0, 0}, fn
        {:ok, {:ok, meta}}, {ok_acc, err_acc} ->
          case Catalog.upsert_dicom_metadata(source.id, meta) do
            {:ok, _} ->
              next_ok = ok_acc + 1
              maybe_broadcast_progress(source.id, total, next_ok, err_acc)
              {next_ok, err_acc}

            {:error, reason} ->
              Catalog.record_ingest_error(source.id, meta.file_path, reason)
              next_err = err_acc + 1
              maybe_broadcast_progress(source.id, total, ok_acc, next_err)
              {ok_acc, next_err}
          end

        {:ok, {:error, path, reason}}, {ok_acc, err_acc} ->
          Catalog.record_ingest_error(source.id, path, reason)
          next_err = err_acc + 1
          maybe_broadcast_progress(source.id, total, ok_acc, next_err)
          {ok_acc, next_err}

        {:exit, reason}, {ok_acc, err_acc} ->
          Catalog.record_ingest_error(source.id, source.root_path, {:worker_exit, reason})
          {ok_acc, err_acc + 1}
      end)

    Catalog.refresh_aggregates()

    {:ok, completed} =
      Catalog.update_archive_source_status(source, %{
        status: "completed",
        files_discovered: total,
        files_indexed: indexed,
        files_quarantined: quarantined,
        last_scanned_at: DateTime.utc_now(:second),
        last_error: nil
      })

    broadcast({:scan_completed, completed})
    {:ok, completed}
  end

  defp parse_isolated(path) do
    case DicomReader.read_metadata(path) do
      {:ok, meta} -> {:ok, meta}
      {:error, reason} -> {:error, path, reason}
    end
  end

  defp discover_candidate_files(root_path) do
    walk_directory(root_path, [])
    |> Enum.sort()
  end

  defp walk_directory(dir, acc) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, inner_acc ->
          if String.starts_with?(entry, ".") do
            inner_acc
          else
            full = Path.join(dir, entry)

            cond do
              File.dir?(full) ->
                walk_directory(full, inner_acc)

              File.regular?(full) and candidate_dicom_file?(full) ->
                [full | inner_acc]

              true ->
                inner_acc
            end
          end
        end)

      {:error, _} ->
        acc
    end
  end

  defp candidate_dicom_file?(path) do
    ext = path |> Path.extname() |> String.downcase()
    MapSet.member?(@dicom_extensions, ext) or has_dicm_magic?(path)
  end

  defp has_dicm_magic?(path) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result =
          case :file.pread(io, 128, 4) do
            {:ok, "DICM"} -> true
            _ -> false
          end

        File.close(io)
        result

      _ ->
        false
    end
  end

  defp maybe_broadcast_progress(source_id, total, indexed, quarantined) do
    processed = indexed + quarantined

    if processed == total or rem(processed, 10) == 0 do
      broadcast(
        {:scan_progress,
         %{
           archive_source_id: source_id,
           files_discovered: total,
           files_indexed: indexed,
           files_quarantined: quarantined
         }}
      )
    end
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, event)
  end
end
