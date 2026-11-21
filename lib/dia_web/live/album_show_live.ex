defmodule DiaWeb.AlbumShowLive do
  @moduledoc """
  Album detail workbench supporting both sharing modes:
  Mode B (standalone virtual DICOMweb links for OHIF Viewer) and
  Mode A (Kheops REST + STOW-RS publication with live upload telemetry).
  """
  use DiaWeb, :live_view

  alias Dia.Albums
  alias Dia.Albums.ShareLink
  alias Dia.Kheops.{Publisher, PublishJob}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    album = Albums.get_album!(id)
    if connected?(socket), do: Publisher.subscribe(album.id)

    share_form =
      to_form(
        %{
          "label" => "Collaborator OHIF Link",
          "deidentify" => album.deidentify_default,
          "expiry_hours" => "168"
        },
        as: :share_link
      )

    kheops_form =
      to_form(
        %{
          "kheops_base_url" => "https://demo.kheops.online",
          "kheops_album_name" => album.name,
          "bearer_token" => "",
          "deidentify" => "true"
        },
        as: :kheops
      )

    ohif_viewer_url =
      Application.get_env(:dia, :ohif_viewer_url, "http://localhost:3000")
      |> String.trim_trailing("/")

    ohif_form = to_form(%{"ohif_viewer_url" => ohif_viewer_url}, as: :ohif)

    {:ok,
     socket
     |> assign(:page_title, album.name)
     |> assign(:album, album)
     |> assign(:summary, Albums.album_summary(album))
     |> assign(:ohif_viewer_url, ohif_viewer_url)
     |> assign(:ohif_form, ohif_form)
     |> assign(:share_form, share_form)
     |> assign(:kheops_form, kheops_form)
     |> assign(:kheops_error, nil)
     |> stream(:share_links, album.share_links)
     |> stream(:publish_jobs, album.kheops_publish_jobs)
     |> stream(:album_series, album.series)}
  end

  @impl true
  def handle_event("update_ohif_url", %{"ohif" => %{"ohif_viewer_url" => url}}, socket) do
    cleaned = url |> String.trim() |> String.trim_trailing("/")
    updated_url = if(cleaned == "", do: "http://localhost:3000", else: cleaned)
    album = Albums.get_album!(socket.assigns.album.id)

    {:noreply,
     socket
     |> assign(:ohif_viewer_url, updated_url)
     |> assign(:ohif_form, to_form(%{"ohif_viewer_url" => updated_url}, as: :ohif))
     |> stream(:share_links, album.share_links, reset: true)}
  end

  @impl true
  def handle_event("create_share_link", %{"share_link" => params}, socket) do
    expires_at = compute_expiry(params["expiry_hours"])

    attrs = %{
      "label" => params["label"],
      "deidentify" => params["deidentify"] in [true, "true"],
      "expires_at" => expires_at
    }

    case Albums.create_share_link(socket.assigns.album, attrs) do
      {:ok, link} ->
        {:noreply,
         socket
         |> stream_insert(:share_links, link, at: 0)
         |> put_flash(:info, "Created virtual DICOMweb share link \"#{link.label}\".")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Provide a valid label for the share link.")}
    end
  end

  @impl true
  def handle_event("revoke_share_link", %{"id" => id}, socket) do
    link = Albums.get_share_link!(id)
    {:ok, revoked} = Albums.revoke_share_link(link)

    {:noreply,
     socket
     |> stream_insert(:share_links, revoked)
     |> put_flash(:info, "Revoked share link \"#{revoked.label}\".")}
  end

  @impl true
  def handle_event("publish_kheops", %{"kheops" => params}, socket) do
    token = params["bearer_token"] || ""

    attrs = %{
      "kheops_base_url" => params["kheops_base_url"],
      "kheops_album_name" => params["kheops_album_name"],
      "deidentify" => params["deidentify"] in [true, "true"]
    }

    case Publisher.publish_async(socket.assigns.album, attrs, token) do
      {:ok, job} ->
        {:noreply,
         socket
         |> assign(:kheops_error, nil)
         |> stream_insert(:publish_jobs, job, at: 0)
         |> put_flash(
           :info,
           "Started Kheops STOW-RS publish job for \"#{job.kheops_album_name}\"."
         )}

      {:error, :missing_token} ->
        {:noreply,
         assign(socket, :kheops_error, "A Kheops OAuth or album bearer token is required.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Enum.map_join("; ", fn {k, v} -> "#{k} #{Enum.join(v, ", ")}" end)

        {:noreply, assign(socket, :kheops_error, msg)}
    end
  end

  @impl true
  def handle_event("remove_series", %{"id" => series_id_str}, socket) do
    series_id = String.to_integer(series_id_str)
    {:ok, updated_album} = Albums.remove_series_from_album(socket.assigns.album, series_id)

    {:noreply,
     socket
     |> assign(:album, updated_album)
     |> assign(:summary, Albums.album_summary(updated_album))
     |> stream(:album_series, updated_album.series, reset: true)
     |> put_flash(:info, "Removed series from album. Underlying local files were not modified.")}
  end

  @impl true
  def handle_info({:publish_progress, %PublishJob{} = job}, socket) do
    {:noreply, stream_insert(socket, :publish_jobs, job)}
  end

  @impl true
  def handle_info({:publish_completed, %PublishJob{} = job}, socket) do
    {:noreply, stream_insert(socket, :publish_jobs, job)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_nav={:albums}>
      <.header>
        {@album.name}
        <:subtitle>
          {@album.description || "Zero-copy virtual DICOM album"} ({@summary.study_count} studies, {@summary.series_count} series, {@summary.instance_count} instances)
        </:subtitle>
        <:actions>
          <.button
            href={~p"/albums/#{@album.id}/manifest.json"}
            variant="secondary"
            id="export-json-btn"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Manifest JSON
          </.button>
          <.button
            href={~p"/albums/#{@album.id}/manifest.csv"}
            variant="secondary"
            id="export-csv-btn"
          >
            <.icon name="hero-table-cells" class="size-4" /> Manifest CSV
          </.button>
          <.button navigate={~p"/albums"} variant="ghost">
            All Albums
          </.button>
        </:actions>
      </.header>

      <div class="mt-6 grid grid-cols-1 gap-6 lg:grid-cols-2">
        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs" id="mode-b-panel">
          <div class="border-b border-slate-100 pb-3">
            <span class="inline-flex rounded-md bg-sky-50 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-sky-800 border border-sky-200">
              Mode B - Standalone Virtual DICOMweb
            </span>
            <h2 class="mt-2 text-base font-semibold text-slate-900">
              Direct OHIF Viewer Share Links
            </h2>
            <p class="mt-1 text-xs text-slate-600">
              Mint capability-scoped QIDO-RS and WADO-RS URLs pointing directly at local DICOM storage with zero file copying.
            </p>
          </div>

          <.form
            for={@ohif_form}
            id="ohif-url-form"
            phx-change="update_ohif_url"
            class="mt-3 rounded-lg border border-slate-200 bg-slate-50/70 p-3"
          >
            <.input
              field={@ohif_form[:ohif_viewer_url]}
              type="url"
              label="OHIF Viewer Base URL (for direct launch)"
              placeholder="http://localhost:3000"
              phx-debounce="300"
            />
          </.form>

          <.form
            for={@share_form}
            id="share-link-form"
            phx-submit="create_share_link"
            class="mt-4 space-y-3"
          >
            <.input field={@share_form[:label]} type="text" label="Link Label" required />
            <.input
              field={@share_form[:expiry_hours]}
              type="select"
              label="Expiration"
              options={[
                {"24 hours", "24"},
                {"7 days", "168"},
                {"30 days", "720"},
                {"No expiration", "never"}
              ]}
            />
            <.input
              field={@share_form[:deidentify]}
              type="checkbox"
              label="Apply PS3.15 de-identification on served metadata & instances"
            />
            <.button type="submit" variant="primary" id="create-share-link-btn" class="w-full">
              <.icon name="hero-link" class="size-4" /> Generate Virtual Album Link
            </.button>
          </.form>

          <div id="share-links-list" phx-update="stream" class="mt-5 divide-y divide-slate-100">
            <div
              id="share-links-empty"
              class="hidden only:block py-4 text-center text-xs text-slate-500"
            >
              No virtual DICOMweb links minted yet.
            </div>
            <div :for={{dom_id, link} <- @streams.share_links} id={dom_id} class="py-3.5 space-y-2">
              <div class="flex items-center justify-between gap-2">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-sm font-semibold text-slate-900">{link.label}</span>
                  <%= if ShareLink.active?(link) do %>
                    <span class="rounded-full border border-emerald-200 bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-800">
                      Active
                    </span>
                  <% else %>
                    <span class="rounded-full border border-slate-200 bg-slate-100 px-2 py-0.5 text-[11px] font-medium text-slate-600">
                      Inactive
                    </span>
                  <% end %>
                  <span
                    :if={link.deidentify}
                    class="rounded-full border border-sky-200 bg-sky-50 px-2 py-0.5 text-[11px] font-medium text-sky-800"
                  >
                    De-ID
                  </span>
                </div>

                <.button
                  :if={ShareLink.active?(link)}
                  type="button"
                  variant="ghost"
                  id={"revoke-link-#{link.id}"}
                  phx-click="revoke_share_link"
                  phx-value-id={link.id}
                >
                  Revoke
                </.button>
              </div>

              <div class="rounded-lg border border-slate-200 bg-slate-50 p-2.5 font-mono text-[11px] text-slate-700 break-all">
                {dicomweb_url(link.token)}
              </div>

              <div class="flex flex-wrap items-center justify-between gap-2 text-xs text-slate-500">
                <span>Requests served: {link.access_count}</span>
                <div class="flex flex-wrap items-center gap-3">
                  <a
                    :if={ShareLink.active?(link)}
                    href={ohif_launch_url(@ohif_viewer_url, link.token)}
                    target="_blank"
                    id={"launch-ohif-#{link.id}"}
                    class="inline-flex items-center gap-1 rounded-md border border-sky-200 bg-sky-50 px-2 py-0.5 font-semibold text-sky-800 hover:bg-sky-100 transition-colors"
                  >
                    <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> Open in OHIF
                  </a>
                  <a
                    href={~p"/dicomweb/albums/#{link.token}/studies"}
                    target="_blank"
                    class="font-medium text-sky-700 hover:underline"
                  >
                    QIDO-RS Studies
                  </a>
                  <a
                    href={~p"/dicomweb/albums/#{link.token}/ohif-config.json"}
                    target="_blank"
                    class="font-medium text-sky-700 hover:underline"
                  >
                    OHIF Config JSON
                  </a>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section class="rounded-xl border border-slate-200 bg-white p-5 shadow-2xs" id="mode-a-panel">
          <div class="border-b border-slate-100 pb-3">
            <span class="inline-flex rounded-md bg-emerald-50 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wide text-emerald-800 border border-emerald-200">
              Mode A - Kheops REST &amp; STOW-RS Bridge
            </span>
            <h2 class="mt-2 text-base font-semibold text-slate-900">
              Publish Album to Kheops
            </h2>
            <p class="mt-1 text-xs text-slate-600">
              Create a Kheops album and stream instances over STOW-RS for native Kheops / OHIF sharing. Tokens stay strictly in memory and are never saved to SQLite.
            </p>
          </div>

          <div
            :if={@kheops_error}
            id="kheops-error-banner"
            class="mt-3 rounded-lg border border-rose-200 bg-rose-50 px-3 py-2 text-xs font-medium text-rose-800"
          >
            {@kheops_error}
          </div>

          <.form
            for={@kheops_form}
            id="kheops-publish-form"
            phx-submit="publish_kheops"
            class="mt-4 space-y-3"
          >
            <.input
              field={@kheops_form[:kheops_base_url]}
              type="url"
              label="Kheops Base URL"
              placeholder="https://demo.kheops.online"
              required
            />
            <.input
              field={@kheops_form[:kheops_album_name]}
              type="text"
              label="Target Kheops Album Name"
              required
            />
            <.input
              field={@kheops_form[:bearer_token]}
              type="password"
              label="Kheops Access / Capability Token (not stored)"
              placeholder="Bearer token"
              required
            />
            <.input
              field={@kheops_form[:deidentify]}
              type="checkbox"
              label="De-identify (PS3.15 with consistent album UID remapping) before upload"
            />
            <.button type="submit" variant="primary" id="publish-kheops-btn" class="w-full">
              <.icon name="hero-cloud-arrow-up" class="size-4" /> Publish to Kheops via STOW-RS
            </.button>
          </.form>

          <div id="kheops-jobs-list" phx-update="stream" class="mt-5 divide-y divide-slate-100">
            <div
              id="kheops-jobs-empty"
              class="hidden only:block py-4 text-center text-xs text-slate-500"
            >
              No Kheops publication runs recorded yet.
            </div>
            <div :for={{dom_id, job} <- @streams.publish_jobs} id={dom_id} class="py-3.5 space-y-1.5">
              <div class="flex items-center justify-between gap-2">
                <span class="text-sm font-semibold text-slate-900">{job.kheops_album_name}</span>
                <.job_badge status={job.status} />
              </div>
              <div class="text-xs text-slate-600">
                Target: <span class="font-mono">{job.kheops_base_url}</span>
              </div>
              <div class="flex flex-wrap items-center gap-4 text-xs text-slate-600">
                <span>Uploaded: <strong>{job.uploaded_count}/{job.total_instances}</strong></span>
                <span>Failed: <strong>{job.failed_count}</strong></span>
                <span :if={job.deidentify} class="text-emerald-700 font-medium">PS3.15 De-ID</span>
              </div>
              <div :if={job.remote_share_url} class="text-xs">
                <a
                  href={job.remote_share_url}
                  target="_blank"
                  class="font-mono text-sky-700 hover:underline break-all"
                >
                  {job.remote_share_url}
                </a>
              </div>
              <pre
                :if={job.error_log}
                class="mt-1 max-h-24 overflow-auto rounded border border-rose-200 bg-rose-50 p-2 text-[11px] text-rose-800"
              >{job.error_log}</pre>
            </div>
          </div>
        </section>
      </div>

      <section class="mt-8">
        <h2 class="mb-3 text-base font-semibold text-slate-900">
          Series Included in Album ({@summary.series_count})
        </h2>

        <div class="overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-2xs">
          <table class="min-w-full divide-y divide-slate-200 text-left text-sm">
            <thead class="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-600">
              <tr>
                <th class="px-4 py-3">Modality</th>
                <th class="px-4 py-3">Study / Patient</th>
                <th class="px-4 py-3">Series Description</th>
                <th class="px-4 py-3">Body Part</th>
                <th class="px-4 py-3 text-right">Instances</th>
                <th class="px-4 py-3 text-right">Action</th>
              </tr>
            </thead>
            <tbody id="album-series-rows" phx-update="stream" class="divide-y divide-slate-100">
              <tr id="album-series-empty" class="hidden only:table-row">
                <td colspan="6" class="px-4 py-8 text-center text-sm text-slate-500">
                  This album currently has no series.
                </td>
              </tr>
              <tr :for={{dom_id, s} <- @streams.album_series} id={dom_id} class="hover:bg-slate-50">
                <td class="px-4 py-3">
                  <span class="inline-flex rounded-md border border-sky-200 bg-sky-50 px-2 py-0.5 text-xs font-semibold text-sky-800">
                    {s.modality || "OT"}
                  </span>
                </td>
                <td class="px-4 py-3">
                  <div class="font-medium text-slate-900">
                    {s.study.study_description || "Untitled Study"}
                  </div>
                  <div class="font-mono text-xs text-slate-500">{s.study.study_instance_uid}</div>
                </td>
                <td class="px-4 py-3 text-slate-800">{s.series_description || "-"}</td>
                <td class="px-4 py-3 text-slate-600">{s.body_part_examined || "-"}</td>
                <td class="px-4 py-3 text-right font-semibold text-slate-800">{s.instance_count}</td>
                <td class="px-4 py-3 text-right">
                  <.button
                    type="button"
                    variant="ghost"
                    id={"remove-series-#{s.id}"}
                    phx-click="remove_series"
                    phx-value-id={s.id}
                  >
                    Remove
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :status, :string, required: true

  defp job_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium border",
      cond do
        @status == "completed" -> "border-emerald-200 bg-emerald-50 text-emerald-800"
        @status == "running" -> "border-sky-200 bg-sky-50 text-sky-800"
        @status == "partial_failure" -> "border-amber-200 bg-amber-50 text-amber-800"
        @status == "failed" -> "border-rose-200 bg-rose-50 text-rose-800"
        true -> "border-slate-200 bg-slate-100 text-slate-700"
      end
    ]}>
      {@status}
    </span>
    """
  end

  defp dicomweb_url(token) do
    DiaWeb.Endpoint.url() <> "/dicomweb/albums/" <> token
  end

  defp ohif_launch_url(ohif_base_url, token) do
    config_url = dicomweb_url(token) <> "/ohif-config.json"
    "#{String.trim_trailing(ohif_base_url, "/")}/viewer?url=#{URI.encode_www_form(config_url)}"
  end

  defp compute_expiry("never"), do: nil
  defp compute_expiry(nil), do: nil
  defp compute_expiry(""), do: nil

  defp compute_expiry(hours_str) do
    case Integer.parse(to_string(hours_str)) do
      {hours, ""} when hours > 0 ->
        DateTime.utc_now(:second) |> DateTime.add(hours * 3600, :second)

      _ ->
        nil
    end
  end
end
