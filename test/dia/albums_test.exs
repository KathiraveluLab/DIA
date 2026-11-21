defmodule Dia.AlbumsTest do
  use Dia.DataCase, async: false

  alias Dia.{Albums, Catalog, DicomFixtures}
  alias Dia.Ingest.Scanner

  setup do
    root = DicomFixtures.create_temp_archive!("albums_test")
    on_exit(fn -> File.rm_rf!(root) end)

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "brain_mr.dcm"), %{
      study_uid: "1.2.826.0.1.3680043.8.498.3001",
      series_uid: "1.2.826.0.1.3680043.8.498.3001.1",
      sop_uid: "1.2.826.0.1.3680043.8.498.3001.1.1",
      modality: "MR",
      body_part: "BRAIN",
      study_date: "20260115",
      institution_name: "UAA Lab",
      study_description: "Glioma Baseline",
      series_description: "T1 Contrast"
    })

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "chest_ct.dcm"), %{
      study_uid: "1.2.826.0.1.3680043.8.498.3002",
      series_uid: "1.2.826.0.1.3680043.8.498.3002.1",
      sop_uid: "1.2.826.0.1.3680043.8.498.3002.1.1",
      modality: "CT",
      body_part: "CHEST",
      study_date: "20260620",
      institution_name: "Anchorage Medical",
      study_description: "Pulmonary Screen",
      series_description: "Axial 1mm"
    })

    {:ok, source} = Catalog.create_archive_source(%{name: "Local Archive", root_path: root})
    {:ok, _} = Scanner.scan_sync(source.id)

    %{root: root, source: source}
  end

  test "filters series by modality, body part, date range, and text query" do
    mr_only = Catalog.search_series(%{"modality" => "MR"})
    assert length(mr_only) == 1
    assert hd(mr_only).body_part_examined == "BRAIN"

    date_filtered = Catalog.search_series(%{"date_from" => "20260501", "date_to" => "20261231"})
    assert length(date_filtered) == 1
    assert hd(date_filtered).modality == "CT"

    text_filtered = Catalog.search_series(%{"q" => "Glioma"})
    assert length(text_filtered) == 1
    assert hd(text_filtered).study.study_description == "Glioma Baseline"
  end

  test "creates zero-copy albums and exports reproducible JSON and CSV cohort manifests" do
    [mr_series] = Catalog.search_series(%{"modality" => "MR"})

    {:ok, album} =
      Albums.create_album(
        %{
          "name" => "Brain T1 Cohort",
          "description" => "Selected MR brain series",
          "query_filter_json" => Jason.encode!(%{"modality" => "MR", "body_part" => "BRAIN"})
        },
        [mr_series.id]
      )

    summary = Albums.album_summary(album)
    assert summary.study_count == 1
    assert summary.series_count == 1
    assert summary.instance_count == 1

    manifest = Albums.export_manifest_map(album)
    assert manifest.name == "Brain T1 Cohort"
    assert manifest.query_filter == %{"modality" => "MR", "body_part" => "BRAIN"}
    assert length(manifest.instances) == 1

    csv = Albums.export_manifest_csv(album)
    assert csv =~ "study_instance_uid,series_instance_uid,sop_instance_uid"
    assert csv =~ "1.2.826.0.1.3680043.8.498.3001.1.1"

    {:ok, updated} = Albums.remove_series_from_album(album, mr_series.id)
    assert Albums.album_summary(updated).series_count == 0
  end
end
