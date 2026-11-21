defmodule DiaWeb.DicomWebControllerTest do
  use DiaWeb.ConnCase, async: false

  alias Dia.{Albums, Catalog, DicomFixtures}
  alias Dia.Ingest.Scanner

  setup do
    root = DicomFixtures.create_temp_archive!("dicomweb_test")
    on_exit(fn -> File.rm_rf!(root) end)

    f1 =
      DicomFixtures.write_synthetic_dcm!(Path.join(root, "included.dcm"), %{
        study_uid: "1.2.826.0.1.3680043.8.498.4001",
        series_uid: "1.2.826.0.1.3680043.8.498.4001.1",
        sop_uid: "1.2.826.0.1.3680043.8.498.4001.1.1",
        modality: "MR",
        patient_name: "DOE^JANE",
        patient_id: "PAT-4001",
        study_description: "Included Study"
      })

    f2 =
      DicomFixtures.write_synthetic_dcm!(Path.join(root, "excluded.dcm"), %{
        study_uid: "1.2.826.0.1.3680043.8.498.4002",
        series_uid: "1.2.826.0.1.3680043.8.498.4002.1",
        sop_uid: "1.2.826.0.1.3680043.8.498.4002.1.1",
        modality: "CT",
        patient_name: "SECRET^OTHER",
        patient_id: "PAT-4002",
        study_description: "Excluded Study"
      })

    {:ok, source} = Catalog.create_archive_source(%{name: "DICOMweb Archive", root_path: root})
    {:ok, _} = Scanner.scan_sync(source.id)

    [mr_series] = Catalog.search_series(%{"modality" => "MR"})
    {:ok, album} = Albums.create_album(%{"name" => "Scoped OHIF Album"}, [mr_series.id])

    {:ok, link} =
      Albums.create_share_link(album, %{"label" => "OHIF Full", "deidentify" => false})

    {:ok, deid_link} =
      Albums.create_share_link(album, %{"label" => "OHIF De-ID", "deidentify" => true})

    %{album: album, link: link, deid_link: deid_link, included: f1, excluded: f2}
  end

  test "serves CORS preflight and strictly album-scoped QIDO-RS and WADO-RS endpoints", %{
    conn: conn,
    link: link,
    included: inc,
    excluded: exc
  } do
    # CORS preflight
    opt_conn = options(conn, "/dicomweb/albums/#{link.token}/studies")
    assert opt_conn.status == 204
    assert get_resp_header(opt_conn, "access-control-allow-origin") == ["*"]

    # QIDO-RS studies returns ONLY included study
    studies_conn = get(conn, "/dicomweb/albums/#{link.token}/studies")
    assert studies_conn.status == 200
    assert hd(get_resp_header(studies_conn, "content-type")) =~ "application/dicom+json"
    studies = Jason.decode!(studies_conn.resp_body)
    assert length(studies) == 1
    assert hd(studies)["0020000D"]["Value"] == [inc.study_uid]

    # QIDO-RS series & instances
    series_conn = get(conn, "/dicomweb/albums/#{link.token}/studies/#{inc.study_uid}/series")
    assert series_conn.status == 200
    assert length(Jason.decode!(series_conn.resp_body)) == 1

    inst_conn =
      get(
        conn,
        "/dicomweb/albums/#{link.token}/studies/#{inc.study_uid}/series/#{inc.series_uid}/instances"
      )

    assert inst_conn.status == 200
    assert length(Jason.decode!(inst_conn.resp_body)) == 1

    # WADO-RS metadata emits BulkDataURI for PixelData
    meta_conn =
      get(
        conn,
        "/dicomweb/albums/#{link.token}/studies/#{inc.study_uid}/series/#{inc.series_uid}/metadata"
      )

    assert meta_conn.status == 200
    [meta] = Jason.decode!(meta_conn.resp_body)
    assert meta["7FE00010"]["BulkDataURI"] =~ "/frames/1"

    # WADO-RS instance retrieval
    wado_conn =
      get(
        conn,
        "/dicomweb/albums/#{link.token}/studies/#{inc.study_uid}/series/#{inc.series_uid}/instances/#{inc.sop_uid}"
      )

    assert wado_conn.status == 200
    assert hd(get_resp_header(wado_conn, "content-type")) =~ "multipart/related"
    assert wado_conn.resp_body =~ "DICM"

    # WADO-RS frame streaming returns exact synthetic pixel buffer
    frame_conn =
      get(
        conn,
        "/dicomweb/albums/#{link.token}/studies/#{inc.study_uid}/series/#{inc.series_uid}/instances/#{inc.sop_uid}/frames/1"
      )

    assert frame_conn.status == 200
    assert hd(get_resp_header(frame_conn, "content-type")) =~ "multipart/related"
    assert :binary.match(frame_conn.resp_body, inc.pixel_bytes) != :nomatch

    # OHIF v3 config JSON endpoint
    ohif_conn = get(conn, "/dicomweb/albums/#{link.token}/ohif-config.json")
    assert ohif_conn.status == 200
    ohif_cfg = Jason.decode!(ohif_conn.resp_body)

    assert hd(ohif_cfg["dataSources"])["configuration"]["wadoRoot"] =~
             "/dicomweb/albums/#{link.token}"

    # Out-of-album study/instance is strictly rejected with 404
    blocked_conn =
      get(
        conn,
        "/dicomweb/albums/#{link.token}/studies/#{exc.study_uid}/series/#{exc.series_uid}/instances/#{exc.sop_uid}"
      )

    assert blocked_conn.status == 404
  end

  test "applies PS3.15 de-identification when enabled on share link", %{
    conn: conn,
    deid_link: link,
    included: inc
  } do
    studies_conn = get(conn, "/dicomweb/albums/#{link.token}/studies")
    assert studies_conn.status == 200
    [study] = Jason.decode!(studies_conn.resp_body)
    assert study["00100010"]["Value"] == [%{"Alphabetic" => "ANONYMOUS"}]
    refute study["00100020"]["Value"] == ["PAT-4001"]

    meta_conn =
      get(
        conn,
        "/dicomweb/albums/#{link.token}/studies/#{inc.study_uid}/series/#{inc.series_uid}/metadata"
      )

    assert meta_conn.status == 200
    [meta] = Jason.decode!(meta_conn.resp_body)
    assert meta["00100010"]["Value"] == [%{"Alphabetic" => "ANONYMOUS"}]
    assert Enum.member?(meta["00120063"]["Value"], "retain_uids")
    refute Map.has_key?(meta, "00080080")
    assert meta["0020000D"]["Value"] == [inc.study_uid]
  end

  test "rejects revoked, expired, and unknown share tokens", %{
    conn: conn,
    album: album,
    link: link
  } do
    {:ok, _} = Albums.revoke_share_link(link)
    assert get(conn, "/dicomweb/albums/#{link.token}/studies").status == 401

    past = DateTime.utc_now(:second) |> DateTime.add(-3600, :second)

    {:ok, expired_link} =
      Albums.create_share_link(album, %{"label" => "Expired", "expires_at" => past})

    assert get(conn, "/dicomweb/albums/#{expired_link.token}/studies").status == 401
    assert get(conn, "/dicomweb/albums/nonexistent-token/studies").status == 404
  end
end
