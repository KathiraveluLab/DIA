defmodule DiaWeb.Layouts do
  @moduledoc """
  Application layouts for the DIA DICOM Image Albums workspace.
  """
  use DiaWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active_nav, :atom, default: :archives, doc: "active navigation tab"
  attr :current_scope, :map, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-50 text-slate-900">
      <header class="sticky top-0 z-30 border-b border-slate-200 bg-white/95 backdrop-blur">
        <div class="mx-auto flex max-w-7xl items-center justify-between px-4 py-3 sm:px-6 lg:px-8">
          <div class="flex items-center gap-8">
            <.link navigate={~p"/"} class="flex items-center gap-2.5 group">
              <div class="flex size-8 items-center justify-center rounded-lg bg-sky-700 text-white shadow-xs group-hover:bg-sky-800 transition-colors">
                <.icon name="hero-square-3-stack-3d" class="size-4" />
              </div>
              <div>
                <div class="text-sm font-bold tracking-tight text-slate-900">DIA</div>
                <div class="text-[11px] font-medium text-slate-500 leading-none">
                  DICOM Image Albums
                </div>
              </div>
            </.link>

            <nav aria-label="Primary" class="flex items-center gap-1">
              <.nav_link navigate={~p"/"} active={@active_nav == :archives} icon="hero-folder-open">
                Archives
              </.nav_link>
              <.nav_link
                navigate={~p"/explorer"}
                active={@active_nav == :explorer}
                icon="hero-magnifying-glass"
              >
                Explorer
              </.nav_link>
              <.nav_link
                navigate={~p"/albums"}
                active={@active_nav == :albums}
                icon="hero-rectangle-stack"
              >
                Albums
              </.nav_link>
            </nav>
          </div>

          <div class="hidden sm:flex items-center gap-2 text-xs text-slate-500">
            <span class="inline-flex items-center gap-1.5 rounded-full border border-emerald-200 bg-emerald-50 px-2.5 py-1 font-medium text-emerald-800">
              <span class="size-1.5 rounded-full bg-emerald-500" /> Local Standalone Mode
            </span>
          </div>
        </div>
      </header>

      <main class="mx-auto max-w-7xl px-4 py-8 sm:px-6 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-sm font-medium transition-colors",
        if(@active,
          do: "bg-sky-50 text-sky-800 border border-sky-200",
          else: "text-slate-600 hover:bg-slate-100 hover:text-slate-900 border border-transparent"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Server connection interrupted")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
