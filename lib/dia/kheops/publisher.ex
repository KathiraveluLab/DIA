defmodule Dia.Kheops.Publisher do
  @moduledoc """
  Orchestrates album publication to Kheops (Mode A), applying optional PS3.15
  de-identification with consistent album-level UID remapping and streaming STOW-RS uploads.
  """

  alias Dia.Albums
  alias Dia.Albums.Album
  alias Dia.Ingest.DicomReader
  alias Dia.Kheops
  alias Dia.Kheops.{Client, PublishJob}

  @pubsub Dia.PubSub

  def topic(album_id), do: "kheops:album:#{album_id}"

  def subscribe(album_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(album_id))
  end

  @doc """
  Creates a publish job record and starts an asynchronous supervised upload task.
  The `bearer_token` is held strictly in process memory and never written to SQLite.
  """
  def publish_async(%Album{} = album, attrs, bearer_token, opts \\ []) do
    with :ok <- validate_token(bearer_token),
         {:ok, job} <- Kheops.create_publish_job(album, attrs) do
      {:ok, _pid} =
        Task.Supervisor.start_child(Dia.TaskSupervisor, fn ->
          execute_job(job, album, bearer_token, opts)
        end)

      {:ok, job}
    end
  end

  @doc """
  Synchronously creates and executes a Kheops publication job (used by tests and batch runs).
  """
  def publish_sync(%Album{} = album, attrs, bearer_token, opts \\ []) do
    with :ok <- validate_token(bearer_token),
         {:ok, job} <- Kheops.create_publish_job(album, attrs) do
      execute_job(job, album, bearer_token, opts)
    end
  end

  defp execute_job(%PublishJob{} = job, %Album{} = album, bearer_token, opts) do
    instances = Albums.list_album_instances(album)
    total = length(instances)
    now = DateTime.utc_now(:second)

    {:ok, job} =
      Kheops.update_publish_job(job, %{
        status: "running",
        total_instances: total,
        started_at: now
      })

    broadcast(album.id, {:publish_progress, job})

    if total == 0 do
      {:ok, failed} =
        Kheops.update_publish_job(job, %{
          status: "failed",
          error_log: "Album contains no indexed DICOM instances to publish.",
          completed_at: DateTime.utc_now(:second)
        })

      broadcast(album.id, {:publish_completed, failed})
      {:error, :empty_album}
    else
      run_publish_pipeline(job, album, instances, bearer_token, opts)
    end
  end

  defp run_publish_pipeline(job, album, instances, bearer_token, opts) do
    use_existing_album_token? = Keyword.get(opts, :use_album_token_directly, false)

    album_setup =
      if use_existing_album_token? do
        {:ok, %{album_id: nil, share_url: job.kheops_base_url}}
      else
        Client.create_album(
          job.kheops_base_url,
          bearer_token,
          job.kheops_album_name,
          album.description,
          opts
        )
      end

    case album_setup do
      {:ok, %{album_id: remote_album_id, share_url: share_url}} ->
        {:ok, job} =
          Kheops.update_publish_job(job, %{
            kheops_album_id: remote_album_id,
            remote_share_url: share_url
          })

        broadcast(album.id, {:publish_progress, job})
        upload_all_instances(job, album, instances, bearer_token, remote_album_id, opts)

      {:error, reason} ->
        {:ok, failed} =
          Kheops.update_publish_job(job, %{
            status: "failed",
            error_log: "Failed to create Kheops album: #{inspect(reason)}",
            completed_at: DateTime.utc_now(:second)
          })

        broadcast(album.id, {:publish_completed, failed})
        {:error, reason}
    end
  end

  defp upload_all_instances(job, album, instances, bearer_token, remote_album_id, opts) do
    stow_opts =
      opts
      |> Keyword.put(:album_id, remote_album_id)

    {uploaded, failed, errors, _uid_map} =
      Enum.reduce(instances, {0, 0, [], %{}}, fn inst, {ok_acc, err_acc, log_acc, uid_map} ->
        case upload_single_instance(inst, job, bearer_token, uid_map, stow_opts) do
          {:ok, next_uid_map} ->
            next_ok = ok_acc + 1
            maybe_report_progress(job, album.id, next_ok, err_acc)
            {next_ok, err_acc, log_acc, next_uid_map}

          {:error, reason, next_uid_map} ->
            next_err = err_acc + 1
            entry = "#{inst.sop_instance_uid}: #{inspect(reason)}"
            maybe_report_progress(job, album.id, ok_acc, next_err)
            {ok_acc, next_err, [entry | log_acc], next_uid_map}
        end
      end)

    final_status =
      cond do
        failed == 0 -> "completed"
        uploaded > 0 -> "partial_failure"
        true -> "failed"
      end

    error_log =
      case Enum.reverse(errors) do
        [] -> nil
        lines -> Enum.join(lines, "\n")
      end

    {:ok, finished} =
      Kheops.update_publish_job(job, %{
        status: final_status,
        uploaded_count: uploaded,
        failed_count: failed,
        error_log: error_log,
        completed_at: DateTime.utc_now(:second)
      })

    broadcast(album.id, {:publish_completed, finished})
    {:ok, finished}
  end

  defp upload_single_instance(inst, job, bearer_token, uid_map, stow_opts) do
    root = inst.archive_source.root_path

    with true <- DicomReader.safe_path?(inst.file_path, root),
         {:ok, binary, next_uid_map} <-
           DicomReader.load_part10_binary(inst.file_path,
             deidentify: job.deidentify,
             retain_uids: false,
             uid_map: uid_map
           ),
         {:ok, _resp} <-
           Client.stow_instance(job.kheops_base_url, bearer_token, binary, stow_opts) do
      {:ok, next_uid_map}
    else
      false -> {:error, :path_outside_archive_root, uid_map}
      {:error, reason} -> {:error, reason, uid_map}
    end
  end

  defp maybe_report_progress(job, album_id, uploaded, failed) do
    processed = uploaded + failed

    if processed == job.total_instances or rem(processed, 5) == 0 do
      {:ok, updated} =
        Kheops.update_publish_job(job, %{
          uploaded_count: uploaded,
          failed_count: failed
        })

      broadcast(album_id, {:publish_progress, updated})
    end
  end

  defp validate_token(token) when is_binary(token) do
    if String.trim(token) != "" do
      :ok
    else
      {:error, :missing_token}
    end
  end

  defp validate_token(_), do: {:error, :missing_token}

  defp broadcast(album_id, event) do
    Phoenix.PubSub.broadcast(@pubsub, topic(album_id), event)
  end
end
