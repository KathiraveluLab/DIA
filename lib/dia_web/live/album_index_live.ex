defmodule DiaWeb.AlbumIndexLive do
  @moduledoc """
  Lists all zero-copy DICOM albums with summary counts and sharing status.
  """
  use DiaWeb, :live_view

  alias Dia.Albums
  alias Dia.Albums.ShareLink

  @impl true
  def mount(_params, _session, socket) do
    albums = Albums.list_albums()

    {:ok,
     socket
     |> assign(:page_title, "Albums")
     |> assign(:albums_count, length(albums))
     |> stream(:albums, albums)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    album = Albums.get_album!(id)
    {:ok, _} = Albums.delete_album(album)

    {:noreply,
     socket
     |> stream_delete(:albums, album)
     |> assign(:albums_count, max(0, socket.assigns.albums_count - 1))
     |> put_flash(:info, "Deleted album \"#{album.name}\". Local DICOM files remain untouched.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={:albums}>
      <.header>
        Shareable DICOM Albums
        <:subtitle>
          Zero-copy virtual cohorts ready for direct OHIF Viewer streaming (Mode B) or Kheops STOW-RS publication (Mode A).
        </:subtitle>
        <:actions>
          <.button navigate={~p"/explorer"} variant="primary" id="new-album-from-explorer-btn">
            <.icon name="hero-plus" class="size-4" /> Build Album in Explorer
          </.button>
        </:actions>
      </.header>

      <div
        id="albums-grid"
        phx-update="stream"
        class="mt-6 grid grid-cols-1 gap-5 md:grid-cols-2 lg:grid-cols-3"
      >
        <div
          id="albums-grid-empty"
          class="hidden only:block md:col-span-2 lg:col-span-3 rounded-xl border border-dashed border-slate-300 bg-white p-12 text-center"
        >
          <p class="text-sm font-medium text-slate-700">No DICOM albums created yet.</p>
          <p class="mt-1 text-xs text-slate-500">
            Use the Metadata Explorer to filter local studies and bundle selected series into a shareable album.
          </p>
          <div class="mt-4">
            <.button navigate={~p"/explorer"} variant="primary">Open Metadata Explorer</.button>
          </div>
        </div>

        <article
          :for={{dom_id, album} <- @streams.albums}
          id={dom_id}
          class="flex flex-col justify-between rounded-xl border border-slate-200 bg-white p-5 shadow-2xs hover:border-sky-300 hover:shadow-sm transition-all"
        >
          <% summary = Albums.album_summary(album) %>
          <% active_links = Enum.count(album.share_links, &ShareLink.active?/1) %>
          <div>
            <div class="flex items-start justify-between gap-2">
              <.link
                navigate={~p"/albums/#{album.id}"}
                class="text-base font-semibold text-slate-900 hover:text-sky-700 transition-colors"
              >
                {album.name}
              </.link>
              <span
                :if={album.deidentify_default}
                class="shrink-0 rounded-full border border-emerald-200 bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-800"
              >
                De-ID Default
              </span>
            </div>

            <p :if={album.description} class="mt-1.5 line-clamp-2 text-xs text-slate-600">
              {album.description}
            </p>

            <div class="mt-4 grid grid-cols-3 gap-2 rounded-lg bg-slate-50 p-2.5 text-center border border-slate-100">
              <div>
                <div class="text-sm font-bold text-slate-900">{summary.study_count}</div>
                <div class="text-[11px] text-slate-500">Studies</div>
              </div>
              <div>
                <div class="text-sm font-bold text-slate-900">{summary.series_count}</div>
                <div class="text-[11px] text-slate-500">Series</div>
              </div>
              <div>
                <div class="text-sm font-bold text-slate-900">{summary.instance_count}</div>
                <div class="text-[11px] text-slate-500">Instances</div>
              </div>
            </div>

            <div class="mt-3 flex flex-wrap items-center gap-2 text-xs text-slate-600">
              <span class="rounded-md bg-sky-50 px-2 py-0.5 font-medium text-sky-800 border border-sky-200">
                {active_links} active OHIF link(s)
              </span>
              <span class="rounded-md bg-slate-100 px-2 py-0.5 font-medium text-slate-700 border border-slate-200">
                {length(album.kheops_publish_jobs)} Kheops job(s)
              </span>
            </div>
          </div>

          <div class="mt-5 flex items-center justify-between border-t border-slate-100 pt-3">
            <.button
              navigate={~p"/albums/#{album.id}"}
              variant="secondary"
              id={"open-album-#{album.id}"}
            >
              Manage &amp; Share
            </.button>
            <.button
              type="button"
              variant="ghost"
              id={"delete-album-#{album.id}"}
              phx-click="delete"
              phx-value-id={album.id}
            >
              <.icon name="hero-trash" class="size-4 text-slate-400 hover:text-rose-600" />
            </.button>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
