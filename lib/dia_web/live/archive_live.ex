defmodule DiaWeb.ArchiveLive do
  @moduledoc """
  Manages local DICOM archive directories, supervised concurrent indexing jobs,
  the built-in pure-Elixir DIMSE Storage SCP receiver, and quarantined file diagnostics.
  """
  use DiaWeb, :live_view

  alias Dia.Catalog
  alias Dia.Catalog.ArchiveSource
  alias Dia.Dimse.Receiver
  alias Dia.Ingest.Scanner

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Scanner.subscribe()
      Receiver.subscribe()
    end

    sources = Catalog.list_archive_sources()
    errors = Catalog.list_ingest_errors(nil, 25)
    dimse_status = Receiver.status()

    default_source_id =
      case sources do
        [first | _] -> Integer.to_string(first.id)
        [] -> ""
      end

    dimse_form =
      to_form(
        %{
          "ae_title" => dimse_status.ae_title,
          "port" => Integer.to_string(dimse_status.port),
          "archive_source_id" =>
            if(dimse_status.archive_source_id,
              do: Integer.to_string(dimse_status.archive_source_id),
              else: default_source_id
            )
        },
        as: :dimse
      )

    {:ok,
     socket
     |> assign(:page_title, "Archives")
     |> assign(:stats, Catalog.catalog_stats())
     |> assign(:sources_list, sources)
     |> assign(:sources_count, length(sources))
     |> assign(:errors_count, length(errors))
     |> assign(:dimse_status, dimse_status)
     |> assign(:dimse_form, dimse_form)
     |> assign(:form, to_form(Catalog.change_archive_source(%ArchiveSource{})))
     |> stream(:sources, sources)
     |> stream(:errors, errors)}
  end

  @impl true
  def handle_event("validate", %{"archive_source" => params}, socket) do
    changeset =
      %ArchiveSource{}
      |> Catalog.change_archive_source(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"archive_source" => params}, socket) do
    case Catalog.create_archive_source(params) do
      {:ok, source} ->
        sources = Catalog.list_archive_sources()

        {:noreply,
         socket
         |> assign(:form, to_form(Catalog.change_archive_source(%ArchiveSource{})))
         |> assign(:sources_list, sources)
         |> assign(:sources_count, length(sources))
         |> assign(:stats, Catalog.catalog_stats())
         |> stream_insert(:sources, source, at: 0)
         |> put_flash(:info, "Archive source \"#{source.name}\" registered.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def handle_event("scan", %{"id" => id}, socket) do
    source = Catalog.get_archive_source!(id)
    {:ok, _pid} = Scanner.start_scan(source.id)

    {:noreply, put_flash(socket, :info, "Started concurrent DICOM scan for \"#{source.name}\".")}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    source = Catalog.get_archive_source!(id)
    {:ok, _} = Catalog.delete_archive_source(source)
    sources = Catalog.list_archive_sources()
    errors = Catalog.list_ingest_errors(nil, 25)

    {:noreply,
     socket
     |> stream_delete(:sources, source)
     |> stream(:errors, errors, reset: true)
     |> assign(:sources_list, sources)
     |> assign(:sources_count, length(sources))
     |> assign(:errors_count, length(errors))
     |> assign(:stats, Catalog.catalog_stats())
     |> put_flash(:info, "Removed archive source \"#{source.name}\".")}
  end

  @impl true
  def handle_event("start_dimse", %{"dimse" => params}, socket) do
    case Receiver.start_scp(params) do
      {:ok, status} ->
        {:noreply,
         socket
         |> assign(:dimse_status, status)
         |> assign(:dimse_form, to_form(params, as: :dimse))
         |> put_flash(
           :info,
           "DIMSE Storage SCP listening as #{status.ae_title} on port #{status.port}."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unable to start DIMSE SCP: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("stop_dimse", _params, socket) do
    {:ok, status} = Receiver.stop_scp()

    {:noreply,
     socket
     |> assign(:dimse_status, status)
     |> put_flash(:info, "Stopped DIMSE Storage SCP listener.")}
  end

  @impl true
  def handle_info({:scan_started, source}, socket) do
    {:noreply,
     socket
     |> stream_insert(:sources, source)
     |> assign(:stats, Catalog.catalog_stats())}
  end

  @impl true
  def handle_info({:scan_progress, %{archive_source_id: id} = progress}, socket) do
    case Catalog.get_archive_source(id) do
      nil ->
        {:noreply, socket}

      source ->
        updated = %{
          source
          | status: "scanning",
            files_discovered: progress.files_discovered,
            files_indexed: progress.files_indexed,
            files_quarantined: progress.files_quarantined
        }

        {:noreply, stream_insert(socket, :sources, updated)}
    end
  end

  @impl true
  def handle_info({:scan_completed, source}, socket) do
    errors = Catalog.list_ingest_errors(nil, 25)

    {:noreply,
     socket
     |> stream_insert(:sources, source)
     |> stream(:errors, errors, reset: true)
     |> assign(:errors_count, length(errors))
     |> assign(:stats, Catalog.catalog_stats())}
  end

  @impl true
  def handle_info({:dimse_status, status}, socket) do
    {:noreply,
     socket
     |> assign(:dimse_status, status)
     |> assign(:stats, Catalog.catalog_stats())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={:archives}>
      <.header>
        Local DICOM Archives
        <:subtitle>
          Register local PACS C-MOVE directories, accept live DIMSE C-STORE pushes, index DICOM Part 10 headers concurrently, and monitor quarantined files.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/explorer"} variant="primary" id="goto-explorer-btn">
            <.icon name="hero-magnifying-glass" class="size-4" /> Explore Metadata
          </.button>
          <.button navigate={~p"/albums"} variant="secondary" id="goto-albums-btn">
            <.icon name="hero-rectangle-stack" class="size-4" /> View Albums
          </.button>
        </:actions>
      </.header>

      <section class="mt-6 grid grid-cols-2 gap-4 lg:grid-cols-5" id="catalog-stats">
        <.stat_card label="Archive Sources" value={@stats.archive_sources} icon="hero-folder" />
        <.stat_card
          label="Indexed Studies"
          value={@stats.studies}
          icon="hero-clipboard-document-list"
        />
        <.stat_card label="Indexed Series" value={@stats.series} icon="hero-squares-2x2" />
        <.stat_card label="DICOM Instances" value={@stats.instances} icon="hero-photo" />
        <.stat_card
          label="Quarantined Files"
          value={@stats.ingest_errors}
          icon="hero-exclamation-triangle"
          tone={if(@stats.ingest_errors > 0, do: :warn, else: :neutral)}
        />
      </section>

      <div class="mt-8 grid grid-cols-1 gap-6 lg:grid-cols-3">
        <div class="space-y-6 lg:col-span-1">
          <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
            <h2 class="text-base font-semibold text-slate-900">Register Archive Directory</h2>
            <p class="mt-1 text-xs text-slate-600">
              Point DIA at a local directory populated by a PACS C-MOVE retriever. Files are read in place without duplication.
            </p>

            <.form
              for={@form}
              id="archive-source-form"
              phx-change="validate"
              phx-submit="save"
              class="mt-4 space-y-3"
            >
              <.input
                field={@form[:name]}
                type="text"
                label="Archive Label"
                placeholder="e.g. Brain MRI Cohort 2026"
                required
              />
              <.input
                field={@form[:root_path]}
                type="text"
                label="Local Directory Path"
                placeholder="e.g. /data/pacs_exports/brain_2026"
                required
              />
              <div class="pt-2">
                <.button type="submit" variant="primary" id="register-archive-btn" class="w-full">
                  <.icon name="hero-plus" class="size-4" /> Register Directory
                </.button>
              </div>
            </.form>
          </section>

          <section
            class="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs"
            id="dimse-scp-panel"
          >
            <div class="flex items-center justify-between gap-2 border-b border-slate-100 pb-3">
              <div>
                <h2 class="text-base font-semibold text-slate-900">DIMSE Storage SCP</h2>
                <p class="text-xs text-slate-500">Pure-Elixir C-ECHO / C-STORE receiver</p>
              </div>
              <span class={[
                "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium",
                if(@dimse_status.running,
                  do: "border-emerald-200 bg-emerald-50 text-emerald-800",
                  else: "border-slate-200 bg-slate-100 text-slate-600"
                )
              ]}>
                <span class={[
                  "size-1.5 rounded-full",
                  if(@dimse_status.running, do: "bg-emerald-500", else: "bg-slate-400")
                ]} />
                {if(@dimse_status.running, do: "Listening", else: "Stopped")}
              </span>
            </div>

            <div
              :if={@dimse_status.running}
              class="mt-3 rounded-lg border border-emerald-200 bg-emerald-50/60 p-3 text-xs text-emerald-900 space-y-1"
            >
              <div>
                AE Title: <strong class="font-mono">{@dimse_status.ae_title}</strong>
                | Port: <strong class="font-mono">{@dimse_status.port}</strong>
              </div>
              <div>Target archive: <strong>{@dimse_status.archive_source_name}</strong></div>
              <div>
                Instances received &amp; indexed: <strong>{@dimse_status.received_count}</strong>
              </div>
            </div>

            <.form
              for={@dimse_form}
              id="dimse-scp-form"
              phx-submit="start_dimse"
              class="mt-3 space-y-2.5"
            >
              <div class="grid grid-cols-2 gap-2">
                <.input field={@dimse_form[:ae_title]} type="text" label="AE Title" required />
                <.input field={@dimse_form[:port]} type="number" label="TCP Port" required />
              </div>
              <.input
                field={@dimse_form[:archive_source_id]}
                type="select"
                label="Destination Archive"
                prompt="Select registered archive..."
                options={Enum.map(@sources_list, &{&1.name, Integer.to_string(&1.id)})}
                required
              />
              <div class="flex items-center gap-2 pt-1">
                <.button
                  type="submit"
                  variant="primary"
                  id="start-dimse-btn"
                  class="flex-1"
                  disabled={@sources_count == 0}
                >
                  <.icon name="hero-signal" class="size-4" />
                  {if(@dimse_status.running, do: "Restart SCP", else: "Start SCP")}
                </.button>
                <.button
                  :if={@dimse_status.running}
                  type="button"
                  variant="danger"
                  id="stop-dimse-btn"
                  phx-click="stop_dimse"
                >
                  Stop
                </.button>
              </div>
            </.form>
          </section>
        </div>

        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs lg:col-span-2">
          <div class="flex items-center justify-between border-b border-slate-100 pb-3">
            <div>
              <h2 class="text-base font-semibold text-slate-900">Registered Local Sources</h2>
              <p class="text-xs text-slate-500">
                {@sources_count} registered source(s)
              </p>
            </div>
          </div>

          <div id="archive-sources-list" phx-update="stream" class="mt-4 divide-y divide-slate-100">
            <div
              id="archive-sources-empty"
              class="hidden only:block py-10 text-center text-sm text-slate-500"
            >
              No local DICOM directories registered yet. Add a directory path on the left to start indexing.
            </div>
            <div
              :for={{dom_id, source} <- @streams.sources}
              id={dom_id}
              class="flex flex-col gap-3 py-4 sm:flex-row sm:items-center sm:justify-between"
            >
              <div class="min-w-0 flex-1">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="font-semibold text-slate-900">{source.name}</span>
                  <.status_badge status={source.status} />
                </div>
                <div class="mt-1 truncate font-mono text-xs text-slate-500" title={source.root_path}>
                  {source.root_path}
                </div>
                <div class="mt-2 flex flex-wrap gap-4 text-xs text-slate-600">
                  <span>Discovered: <strong>{source.files_discovered}</strong></span>
                  <span>Indexed: <strong class="text-emerald-700">{source.files_indexed}</strong></span>
                  <span>
                    Quarantined:
                    <strong class={
                      if(source.files_quarantined > 0, do: "text-amber-700", else: "text-slate-700")
                    }>
                      {source.files_quarantined}
                    </strong>
                  </span>
                </div>
                <p :if={source.last_error} class="mt-1 text-xs text-rose-600">
                  {source.last_error}
                </p>
              </div>

              <div class="flex shrink-0 items-center gap-2">
                <.button
                  type="button"
                  variant="primary"
                  id={"scan-source-#{source.id}"}
                  phx-click="scan"
                  phx-value-id={source.id}
                  disabled={source.status == "scanning"}
                >
                  <.icon
                    name="hero-arrow-path"
                    class={["size-4", source.status == "scanning" && "motion-safe:animate-spin"]}
                  />
                  {if(source.status == "scanning", do: "Scanning...", else: "Scan")}
                </.button>
                <.button
                  type="button"
                  variant="ghost"
                  id={"delete-source-#{source.id}"}
                  phx-click="delete"
                  phx-value-id={source.id}
                >
                  <.icon name="hero-trash" class="size-4 text-slate-500 hover:text-rose-600" />
                </.button>
              </div>
            </div>
          </div>
        </section>
      </div>

      <section class="mt-8 rounded-xl border border-slate-200 bg-white p-5 shadow-2xs">
        <div class="flex items-center justify-between border-b border-slate-100 pb-3">
          <div>
            <h2 class="text-base font-semibold text-slate-900">Quarantined Files</h2>
            <p class="text-xs text-slate-500">
              Malformed or unreadable DICOM files isolated during scanning without halting batch indexing ({@errors_count} shown).
            </p>
          </div>
        </div>

        <div id="ingest-errors-list" phx-update="stream" class="mt-3 divide-y divide-slate-100">
          <div
            id="ingest-errors-empty"
            class="hidden only:block py-6 text-center text-sm text-slate-500"
          >
            No quarantined files recorded.
          </div>
          <div
            :for={{dom_id, err} <- @streams.errors}
            id={dom_id}
            class="flex flex-col gap-1 py-2.5 text-xs sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="min-w-0 font-mono text-slate-700 truncate" title={err.file_path}>
              {err.file_path}
            </div>
            <span class="shrink-0 rounded-md bg-amber-50 px-2 py-0.5 font-medium text-amber-800 border border-amber-200">
              {err.error_reason}
            </span>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :tone, :atom, default: :neutral

  defp stat_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-2xs">
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium uppercase tracking-wide text-slate-500">{@label}</span>
        <.icon
          name={@icon}
          class={[
            "size-4",
            if(@tone == :warn, do: "text-amber-600", else: "text-sky-700")
          ]}
        />
      </div>
      <div class="mt-2 text-2xl font-bold tracking-tight text-slate-900">{@value}</div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium border",
      cond do
        @status == "completed" -> "border-emerald-200 bg-emerald-50 text-emerald-800"
        @status == "scanning" -> "border-sky-200 bg-sky-50 text-sky-800"
        @status == "error" -> "border-rose-200 bg-rose-50 text-rose-800"
        true -> "border-slate-200 bg-slate-100 text-slate-700"
      end
    ]}>
      {@status}
    </span>
    """
  end
end
