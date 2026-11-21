defmodule DiaWeb.Router do
  use DiaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DiaWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :dicomweb do
    plug DiaWeb.Plugs.DicomWebCors
  end

  scope "/", DiaWeb do
    pipe_through :browser

    live "/", ArchiveLive, :index
    live "/explorer", ExplorerLive, :index
    live "/albums", AlbumIndexLive, :index
    live "/albums/:id", AlbumShowLive, :show

    get "/albums/:id/manifest.json", ManifestController, :export_json
    get "/albums/:id/manifest.csv", ManifestController, :export_csv
  end

  scope "/dicomweb", DiaWeb do
    pipe_through :dicomweb

    options "/*path", DicomWebController, :options

    get "/albums/:token/ohif-config.json", DicomWebController, :ohif_config
    get "/albums/:token/studies", DicomWebController, :qido_studies
    get "/albums/:token/studies/:study_uid/series", DicomWebController, :qido_series

    get "/albums/:token/studies/:study_uid/series/:series_uid/instances",
        DicomWebController,
        :qido_instances

    get "/albums/:token/studies/:study_uid/series/:series_uid/metadata",
        DicomWebController,
        :wado_series_metadata

    get "/albums/:token/studies/:study_uid/series/:series_uid/instances/:sop_uid",
        DicomWebController,
        :wado_instance

    get "/albums/:token/studies/:study_uid/series/:series_uid/instances/:sop_uid/frames/:frames",
        DicomWebController,
        :wado_frames
  end

  if Application.compile_env(:dia, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: DiaWeb.Telemetry
    end
  end
end
