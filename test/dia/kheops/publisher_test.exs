defmodule Dia.Kheops.PublisherTest do
  use Dia.DataCase, async: false

  alias Dia.{Albums, Catalog, DicomFixtures}
  alias Dia.Ingest.Scanner
  alias Dia.Kheops.Publisher

  setup do
    root = DicomFixtures.create_temp_archive!("kheops_test")
    on_exit(fn -> File.rm_rf!(root) end)

    study_uid = "1.2.826.0.1.3680043.8.498.5001"
    series_uid = "1.2.826.0.1.3680043.8.498.5001.1"

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "slice1.dcm"), %{
      study_uid: study_uid,
      series_uid: series_uid,
      sop_uid: "1.2.826.0.1.3680043.8.498.5001.1.1",
      patient_name: "SENSITIVE^PATIENT",
      patient_id: "PHI-999"
    })

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "slice2.dcm"), %{
      study_uid: study_uid,
      series_uid: series_uid,
      sop_uid: "1.2.826.0.1.3680043.8.498.5001.1.2",
      patient_name: "SENSITIVE^PATIENT",
      patient_id: "PHI-999"
    })

    {:ok, source} = Catalog.create_archive_source(%{name: "Kheops Source", root_path: root})
    {:ok, _} = Scanner.scan_sync(source.id)

    series = Catalog.search_series(%{})

    {:ok, album} =
      Albums.create_album(%{"name" => "Kheops Publish Album"}, Enum.map(series, & &1.id))

    %{album: album, orig_study_uid: study_uid}
  end

  test "creates Kheops album, uploads de-identified instances via STOW-RS with consistent UID remapping",
       %{album: album, orig_study_uid: orig_study_uid} do
    parent = self()

    stub_plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/api/albums"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-kheops-token"]
          decoded = Jason.decode!(body)
          assert decoded["album_name"] == "Remote Research Cohort"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"album_id" => "alb_xyz123"}))

        {"POST", "/api/studies"} ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-kheops-token"]
          [ct] = Plug.Conn.get_req_header(conn, "content-type")
          assert ct =~ ~s(multipart/related; type="application/dicom")
          send(parent, {:stow_body, body})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "stored"}))
      end
    end

    {:ok, job} =
      Publisher.publish_sync(
        album,
        %{
          "kheops_base_url" => "https://kheops.example.org",
          "kheops_album_name" => "Remote Research Cohort",
          "deidentify" => true
        },
        "secret-kheops-token",
        req_options: [plug: stub_plug]
      )

    assert job.status == "completed"
    assert job.kheops_album_id == "alb_xyz123"
    assert job.remote_share_url == "https://kheops.example.org/albums/alb_xyz123"
    assert job.total_instances == 2
    assert job.uploaded_count == 2
    assert job.failed_count == 0

    # Verify uploaded multipart binaries are valid de-identified DICOMs sharing the SAME remapped Study UID
    assert_received {:stow_body, raw1}
    assert_received {:stow_body, raw2}

    {:ok, ds1} = raw1 |> extract_multipart_dicom() |> Dicom.parse()
    {:ok, ds2} = raw2 |> extract_multipart_dicom() |> Dicom.parse()

    assert String.trim(Dicom.DataSet.get(ds1, {0x0010, 0x0010})) == "ANONYMOUS"
    assert String.trim(Dicom.DataSet.get(ds1, {0x0012, 0x0062})) == "YES"

    remapped_study_1 = String.trim_trailing(Dicom.DataSet.get(ds1, {0x0020, 0x000D}), <<0>>)
    remapped_study_2 = String.trim_trailing(Dicom.DataSet.get(ds2, {0x0020, 0x000D}), <<0>>)

    assert remapped_study_1 != orig_study_uid
    assert remapped_study_1 == remapped_study_2
    assert Dicom.DataSet.get(ds1, {0x0008, 0x0018}) != Dicom.DataSet.get(ds2, {0x0008, 0x0018})
  end

  test "records partial_failure accurately when one STOW-RS upload fails", %{album: album} do
    counter = :counters.new(1, [])

    stub_plug = fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/api/albums" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(201, Jason.encode!(%{"album_id" => "alb_partial"}))

        "/api/studies" ->
          :counters.add(counter, 1, 1)

          if :counters.get(counter, 1) == 1 do
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, "{}")
          else
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(500, Jason.encode!(%{"error" => "storage full"}))
          end
      end
    end

    {:ok, job} =
      Publisher.publish_sync(
        album,
        %{
          "kheops_base_url" => "https://kheops.example.org",
          "kheops_album_name" => "Partial Test",
          "deidentify" => false
        },
        "token-123",
        req_options: [plug: stub_plug]
      )

    assert job.status == "partial_failure"
    assert job.uploaded_count == 1
    assert job.failed_count == 1
    assert job.error_log =~ "500"
  end

  defp extract_multipart_dicom(body) do
    [_headers, rest] = String.split(body, "\r\n\r\n", parts: 2)
    [dicom_bin, _closing] = String.split(rest, "\r\n--dia_stow_", parts: 2)
    dicom_bin
  end
end
