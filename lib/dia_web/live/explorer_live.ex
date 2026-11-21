defmodule DiaWeb.ExplorerLive do
  @moduledoc """
  Faceted DICOM metadata explorer and zero-copy cohort album builder.
  """
  use DiaWeb, :live_view

  alias Dia.Albums
  alias Dia.Albums.Album
  alias Dia.Catalog

  @default_filters %{
    "q" => "",
    "modality" => "",
    "body_part" => "",
    "institution" => "",
    "date_from" => "",
    "date_to" => "",
    "archive_source_id" => ""
  }

  @impl true
  def mount(_params, _session, socket) do
    facets = Catalog.list_filter_facets()
    sources = Catalog.list_archive_sources()
    series = Catalog.search_series(@default_filters)

    {:ok,
     socket
     |> assign(:page_title, "Metadata Explorer")
     |> assign(:facets, facets)
     |> assign(:sources, sources)
     |> assign(:filters, @default_filters)
     |> assign(:filter_form, to_form(@default_filters, as: :filters))
     |> assign(:album_form, to_form(Albums.change_album(%Album{})))
     |> assign(:visible_series, series)
     |> assign(:visible_count, length(series))
     |> assign(:selected_ids, MapSet.new())
     |> stream(:series, series)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filter_params}, socket) do
    filters = Map.merge(@default_filters, filter_params)
    series = Catalog.search_series(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, to_form(filters, as: :filters))
     |> assign(:visible_series, series)
     |> assign(:visible_count, length(series))
     |> stream(:series, series, reset: true)}
  end

  @impl true
  def handle_event("reset_filters", _params, socket) do
    series = Catalog.search_series(@default_filters)

    {:noreply,
     socket
     |> assign(:filters, @default_filters)
     |> assign(:filter_form, to_form(@default_filters, as: :filters))
     |> assign(:visible_series, series)
     |> assign(:visible_count, length(series))
     |> stream(:series, series, reset: true)}
  end

  @impl true
  def handle_event("toggle_series", %{"id" => id_str}, socket) do
    series_id = String.to_integer(id_str)
    selected = socket.assigns.selected_ids

    updated_selected =
      if MapSet.member?(selected, series_id) do
        MapSet.delete(selected, series_id)
      else
        MapSet.put(selected, series_id)
      end

    series_item = Enum.find(socket.assigns.visible_series, &(&1.id == series_id))

    socket =
      socket
      |> assign(:selected_ids, updated_selected)

    socket =
      if series_item do
        stream_insert(socket, :series, series_item)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_all_visible", _params, socket) do
    visible_ids = Enum.map(socket.assigns.visible_series, & &1.id)
    updated_selected = MapSet.union(socket.assigns.selected_ids, MapSet.new(visible_ids))

    {:noreply,
     socket
     |> assign(:selected_ids, updated_selected)
     |> stream(:series, socket.assigns.visible_series, reset: true)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_ids, MapSet.new())
     |> stream(:series, socket.assigns.visible_series, reset: true)}
  end

  @impl true
  def handle_event("create_album", %{"album" => album_params}, socket) do
    selected_ids = MapSet.to_list(socket.assigns.selected_ids)

    if selected_ids == [] do
      {:noreply,
       put_flash(socket, :error, "Select at least one DICOM series before creating an album.")}
    else
      active_filters =
        socket.assigns.filters
        |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
        |> Map.new()

      params_with_query =
        Map.put(album_params, "query_filter_json", Jason.encode!(active_filters))

      case Albums.create_album(params_with_query, selected_ids) do
        {:ok, album} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Album \"#{album.name}\" created with #{length(selected_ids)} series."
           )
           |> push_navigate(to: ~p"/albums/#{album.id}")}

        {:error, changeset} ->
          {:noreply, assign(socket, :album_form, to_form(changeset))}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={:explorer}>
      <.header>
        DICOM Metadata Explorer
        <:subtitle>
          Query indexed local DICOM metadata by modality, anatomy, study date, or text to assemble zero-copy shareable albums.
        </:subtitle>
        <:actions>
          <.button navigate={~p"/"} variant="secondary">
            <.icon name="hero-folder-open" class="size-4" /> Manage Archives
          </.button>
        </:actions>
      </.header>

      <div class="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-12">
        <aside class="space-y-6 lg:col-span-3">
          <div class="rounded-xl border border-slate-200 bg-white p-4 shadow-2xs">
            <div class="flex items-center justify-between pb-3 border-b border-slate-100">
              <h2 class="text-sm font-semibold text-slate-900">Metadata Filters</h2>
              <button
                type="button"
                id="reset-filters-btn"
                phx-click="reset_filters"
                class="text-xs font-medium text-sky-700 hover:text-sky-900 cursor-pointer"
              >
                Reset
              </button>
            </div>

            <.form
              for={@filter_form}
              id="explorer-filter-form"
              phx-change="filter"
              class="mt-3 space-y-2.5"
            >
              <.input
                field={@filter_form[:q]}
                type="search"
                label="Search Metadata"
                placeholder="Patient, description, protocol, UID..."
                phx-debounce="200"
              />
              <.input
                field={@filter_form[:modality]}
                type="select"
                label="Modality"
                prompt="All modalities"
                options={@facets.modalities}
              />
              <.input
                field={@filter_form[:body_part]}
                type="select"
                label="Body Part"
                prompt="All body parts"
                options={@facets.body_parts}
              />
              <.input
                field={@filter_form[:institution]}
                type="select"
                label="Institution"
                prompt="All institutions"
                options={@facets.institutions}
              />
              <.input
                field={@filter_form[:archive_source_id]}
                type="select"
                label="Archive Source"
                prompt="All local archives"
                options={Enum.map(@sources, &{&1.name, &1.id})}
              />
              <div class="grid grid-cols-2 gap-2">
                <.input
                  field={@filter_form[:date_from]}
                  type="text"
                  label="Date From"
                  placeholder="YYYYMMDD"
                />
                <.input
                  field={@filter_form[:date_to]}
                  type="text"
                  label="Date To"
                  placeholder="YYYYMMDD"
                />
              </div>
            </.form>
          </div>

          <div class="rounded-xl border border-sky-200 bg-white p-4 shadow-2xs">
            <h2 class="text-sm font-semibold text-slate-900">Create Zero-Copy Album</h2>
            <p class="mt-1 text-xs text-slate-600">
              Selected series:
              <strong id="selected-series-count" class="text-sky-800">{MapSet.size(@selected_ids)}</strong>
            </p>

            <.form
              for={@album_form}
              id="create-album-form"
              phx-submit="create_album"
              class="mt-3 space-y-2.5"
            >
              <.input
                field={@album_form[:name]}
                type="text"
                label="Album Name"
                placeholder="e.g. T1 Brain Cohort"
                required
              />
              <.input
                field={@album_form[:description]}
                type="textarea"
                label="Description"
                rows="2"
                placeholder="Notes on cohort inclusion criteria..."
              />
              <.input
                field={@album_form[:deidentify_default]}
                type="checkbox"
                label="Default to PS3.15 de-identification"
              />
              <.button
                type="submit"
                variant="primary"
                id="create-album-submit-btn"
                class="w-full"
                disabled={MapSet.size(@selected_ids) == 0}
              >
                <.icon name="hero-rectangle-stack" class="size-4" />
                Create Album ({MapSet.size(@selected_ids)})
              </.button>
            </.form>
          </div>
        </aside>

        <section class="lg:col-span-9">
          <div class="mb-3 flex flex-wrap items-center justify-between gap-2 rounded-xl border border-slate-200 bg-white px-4 py-3 shadow-2xs">
            <div class="text-sm text-slate-700">
              Showing <strong id="visible-series-count">{@visible_count}</strong> matching series
            </div>
            <div class="flex items-center gap-2">
              <.button
                type="button"
                variant="secondary"
                id="select-all-visible-btn"
                phx-click="select_all_visible"
                disabled={@visible_count == 0}
              >
                Select All Visible
              </.button>
              <.button
                type="button"
                variant="ghost"
                id="clear-selection-btn"
                phx-click="clear_selection"
                disabled={MapSet.size(@selected_ids) == 0}
              >
                Clear Selection
              </.button>
            </div>
          </div>

          <div class="overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-2xs">
            <table class="min-w-full divide-y divide-slate-200 text-left text-sm">
              <thead class="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-600">
                <tr>
                  <th class="w-10 px-4 py-3">Select</th>
                  <th class="px-4 py-3">Modality</th>
                  <th class="px-4 py-3">Patient / Study</th>
                  <th class="px-4 py-3">Series / Body Part</th>
                  <th class="px-4 py-3">Date</th>
                  <th class="px-4 py-3 text-right">Instances</th>
                </tr>
              </thead>
              <tbody id="explorer-series-rows" phx-update="stream" class="divide-y divide-slate-100">
                <tr id="explorer-series-empty" class="hidden only:table-row">
                  <td colspan="6" class="px-4 py-12 text-center text-sm text-slate-500">
                    No indexed DICOM series match your current filters. Register and scan an archive first or clear filters.
                  </td>
                </tr>
                <tr
                  :for={{dom_id, s} <- @streams.series}
                  id={dom_id}
                  class={[
                    "transition-colors",
                    if(MapSet.member?(@selected_ids, s.id),
                      do: "bg-sky-50/70 hover:bg-sky-50",
                      else: "hover:bg-slate-50"
                    )
                  ]}
                >
                  <td class="px-4 py-3">
                    <input
                      type="checkbox"
                      id={"select-series-#{s.id}"}
                      checked={MapSet.member?(@selected_ids, s.id)}
                      phx-click="toggle_series"
                      phx-value-id={s.id}
                      class="size-4 rounded border-slate-300 text-sky-700 focus:ring-sky-600 cursor-pointer"
                    />
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap">
                    <span class="inline-flex rounded-md border border-sky-200 bg-sky-50 px-2 py-0.5 text-xs font-semibold text-sky-800">
                      {s.modality || "OT"}
                    </span>
                  </td>
                  <td class="px-4 py-3">
                    <div class="font-medium text-slate-900">
                      {s.study.study_description || "Untitled Study"}
                    </div>
                    <div class="text-xs text-slate-500">
                      ID: {s.study.patient_id || "N/A"} | {s.study.institution_name || "Local Archive"}
                    </div>
                  </td>
                  <td class="px-4 py-3">
                    <div class="text-slate-800">
                      {s.series_description || "Series #{s.series_number || s.id}"}
                    </div>
                    <div class="text-xs text-slate-500">
                      {s.body_part_examined || "Unspecified anatomy"}
                    </div>
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap font-mono text-xs text-slate-600">
                    {s.study.study_date || "-"}
                  </td>
                  <td class="px-4 py-3 whitespace-nowrap text-right font-semibold text-slate-800">
                    {s.instance_count}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
