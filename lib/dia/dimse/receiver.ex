defmodule Dia.Dimse.Receiver do
  @moduledoc """
  Supervised GenServer managing DIA's built-in pure-Elixir DIMSE Storage SCP listener.
  Enables direct PACS C-MOVE / C-STORE ingestion into a registered local archive source
  with live PubSub status notifications.
  """

  use GenServer

  alias Dia.Catalog

  @pubsub Dia.PubSub
  @topic "dimse:updates"
  @target_key {__MODULE__, :active_target}

  defstruct running: false,
            listener_ref: nil,
            port: 11112,
            ae_title: "DIA_SCP",
            archive_source_id: nil,
            archive_source_name: nil,
            root_path: nil,
            received_count: 0,
            last_sop_uid: nil,
            started_at: nil

  def topic, do: @topic

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def start_scp(opts) when is_list(opts) or is_map(opts) do
    GenServer.call(__MODULE__, {:start_scp, Map.new(opts)})
  end

  def stop_scp do
    GenServer.call(__MODULE__, :stop_scp)
  end

  def record_received(sop_uid) do
    GenServer.cast(__MODULE__, {:record_received, sop_uid})
  end

  def active_target do
    case :persistent_term.get(@target_key, nil) do
      %{archive_source_id: id, root_path: path} when is_integer(id) and is_binary(path) ->
        {:ok, %{archive_source_id: id, root_path: path}}

      _ ->
        :error
    end
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    :persistent_term.erase(@target_key)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  @impl true
  def handle_call({:start_scp, params}, _from, %{running: true} = state) do
    _ = stop_listener_safely(state)
    do_start_scp(params, %__MODULE__{})
  end

  @impl true
  def handle_call({:start_scp, params}, _from, state) do
    do_start_scp(params, state)
  end

  @impl true
  def handle_call(:stop_scp, _from, state) do
    _ = stop_listener_safely(state)
    :persistent_term.erase(@target_key)

    next_state = %{
      state
      | running: false,
        listener_ref: nil,
        started_at: nil
    }

    broadcast(next_state)
    {:reply, {:ok, public_status(next_state)}, next_state}
  end

  @impl true
  def handle_cast({:record_received, sop_uid}, state) do
    next_state = %{
      state
      | received_count: state.received_count + 1,
        last_sop_uid: sop_uid
    }

    broadcast(next_state)
    {:noreply, next_state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = stop_listener_safely(state)
    :persistent_term.erase(@target_key)
    :ok
  end

  defp do_start_scp(params, state) do
    port = parse_port(params[:port] || params["port"] || state.port)
    ae_title = String.trim(to_string(params[:ae_title] || params["ae_title"] || "DIA_SCP"))
    source_id = parse_int(params[:archive_source_id] || params["archive_source_id"])

    with {:ok, port} <- validate_port(port),
         true <- ae_title != "" and byte_size(ae_title) <= 16,
         source when not is_nil(source) <- source_id && Catalog.get_archive_source(source_id),
         true <- File.dir?(source.root_path) do
      :persistent_term.put(@target_key, %{
        archive_source_id: source.id,
        root_path: source.root_path
      })

      case Dimse.start_listener(
             port: port,
             ae_title: ae_title,
             handler: Dia.Dimse.StorageHandler
           ) do
        {:ok, ref} ->
          next_state = %__MODULE__{
            running: true,
            listener_ref: ref,
            port: port,
            ae_title: ae_title,
            archive_source_id: source.id,
            archive_source_name: source.name,
            root_path: source.root_path,
            received_count: 0,
            last_sop_uid: nil,
            started_at: DateTime.utc_now(:second)
          }

          broadcast(next_state)
          {:reply, {:ok, public_status(next_state)}, next_state}

        {:error, reason} ->
          :persistent_term.erase(@target_key)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      nil -> {:reply, {:error, :invalid_archive_source}, state}
      false -> {:reply, {:error, :invalid_scp_configuration}, state}
    end
  end

  defp stop_listener_safely(%{running: true, listener_ref: ref}) when not is_nil(ref) do
    Dimse.stop_listener(ref)
  rescue
    _ -> :ok
  end

  defp stop_listener_safely(_), do: :ok

  defp public_status(%__MODULE__{} = state) do
    %{
      running: state.running,
      port: state.port,
      ae_title: state.ae_title,
      archive_source_id: state.archive_source_id,
      archive_source_name: state.archive_source_name,
      root_path: state.root_path,
      received_count: state.received_count,
      last_sop_uid: state.last_sop_uid,
      started_at: state.started_at
    }
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:dimse_status, public_status(state)})
  end

  defp parse_port(p) when is_integer(p), do: p

  defp parse_port(p) when is_binary(p) do
    case Integer.parse(String.trim(p)) do
      {n, ""} -> n
      _ -> :invalid
    end
  end

  defp parse_port(_), do: :invalid

  defp validate_port(p) when is_integer(p) and p >= 1024 and p <= 65535, do: {:ok, p}
  defp validate_port(_), do: {:error, :invalid_port}

  defp parse_int(i) when is_integer(i), do: i

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_int(_), do: nil
end
