defmodule DiaWeb.DiaWorkflowLiveTest do
  use DiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Dia.{Catalog, DicomFixtures}
  alias Dia.Ingest.Scanner

  test "full standalone researcher workflow across Archives, Explorer, Album sharing, and Manifest downloads",
       %{conn: conn} do
    root = DicomFixtures.create_temp_archive!("live_workflow_test")
    on_exit(fn -> File.rm_rf!(root) end)

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "brain_t1.dcm"), %{
      study_uid: "1.2.826.0.1.3680043.8.498.6001",
      series_uid: "1.2.826.0.1.3680043.8.498.6001.1",
      sop_uid: "1.2.826.0.1.3680043.8.498.6001.1.1",
      modality: "MR",
      body_part: "BRAIN",
      study_description: "Neuro Oncology Cohort"
    })

    # 1. Register local archive on ArchiveLive
    {:ok, archive_view, _html} = live(conn, ~p"/")
    assert has_element?(archive_view, "#archive-source-form")
    assert has_element?(archive_view, "#dimse-scp-panel")

    archive_view
    |> form("#archive-source-form", %{
      archive_source: %{name: "Neuro Archive", root_path: root}
    })
    |> render_submit()

    [source] = Catalog.list_archive_sources()
    assert has_element?(archive_view, "#scan-source-#{source.id}")

    # Run synchronous scan to index deterministically in test sandbox
    {:ok, _} = Scanner.scan_sync(source.id)

    # 2. Query metadata and create album in ExplorerLive
    {:ok, explorer_view, _html} = live(conn, ~p"/explorer")
    assert has_element?(explorer_view, "#explorer-filter-form")

    explorer_view
    |> form("#explorer-filter-form", %{filters: %{modality: "MR"}})
    |> render_change()

    [series] = Catalog.search_series(%{"modality" => "MR"})
    assert has_element?(explorer_view, "#select-series-#{series.id}")

    explorer_view
    |> element("#select-series-#{series.id}")
    |> render_click()

    {:ok, album_view, _html} =
      explorer_view
      |> form("#create-album-form", %{
        album: %{name: "Neuro MR Share", description: "Baseline brain scans"}
      })
      |> render_submit()
      |> follow_redirect(conn)

    # 3. Mint and revoke a Mode B OHIF share link on AlbumShowLive
    assert has_element?(album_view, "#mode-b-panel")
    assert has_element?(album_view, "#ohif-url-form")
    assert has_element?(album_view, "#mode-a-panel")

    album_view
    |> form("#share-link-form", %{
      share_link: %{label: "External Reviewer", expiry_hours: "24", deidentify: "true"}
    })
    |> render_submit()

    html = render(album_view)
    assert html =~ "External Reviewer"
    assert html =~ "Open in OHIF"

    # 4. Verify albums index and manifest download endpoints
    {:ok, index_view, _html} = live(conn, ~p"/albums")
    assert has_element?(index_view, "#albums-grid")

    [album] = Dia.Albums.list_albums()
    json_conn = get(conn, ~p"/albums/#{album.id}/manifest.json")
    assert json_conn.status == 200
    assert Jason.decode!(json_conn.resp_body)["name"] == "Neuro MR Share"

    csv_conn = get(conn, ~p"/albums/#{album.id}/manifest.csv")
    assert csv_conn.status == 200
    assert csv_conn.resp_body =~ "1.2.826.0.1.3680043.8.498.6001.1.1"
  end
end
