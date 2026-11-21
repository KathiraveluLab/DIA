defmodule Dia.Ingest.ScannerTest do
  use Dia.DataCase, async: false

  alias Dia.Catalog
  alias Dia.DicomFixtures
  alias Dia.Ingest.{DicomReader, Scanner}

  test "indexes valid DICOM hierarchy concurrently and quarantines corrupt files without halting" do
    root = DicomFixtures.create_temp_archive!("scanner_test")
    on_exit(fn -> File.rm_rf!(root) end)

    study_uid = "1.2.826.0.1.3680043.8.498.1001"
    series_mr = "1.2.826.0.1.3680043.8.498.1001.1"
    series_ct = "1.2.826.0.1.3680043.8.498.2002.1"

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "mr/slice1.dcm"), %{
      study_uid: study_uid,
      series_uid: series_mr,
      sop_uid: "1.2.826.0.1.3680043.8.498.1001.1.1",
      modality: "MR",
      body_part: "BRAIN",
      instance_number: "1"
    })

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "mr/slice2.dcm"), %{
      study_uid: study_uid,
      series_uid: series_mr,
      sop_uid: "1.2.826.0.1.3680043.8.498.1001.1.2",
      modality: "MR",
      body_part: "BRAIN",
      instance_number: "2"
    })

    DicomFixtures.write_synthetic_dcm!(Path.join(root, "ct/chest1.dcm"), %{
      study_uid: "1.2.826.0.1.3680043.8.498.2002",
      series_uid: series_ct,
      sop_uid: "1.2.826.0.1.3680043.8.498.2002.1.1",
      modality: "CT",
      body_part: "CHEST",
      study_description: "Thorax CT",
      series_description: "Lung Window"
    })

    corrupt_path = Path.join(root, "corrupt_file.dcm")
    File.write!(corrupt_path, "not a valid dicom part 10 binary payload")
    File.write!(Path.join(root, ".hidden.dcm"), "ignored hidden file")

    {:ok, source} = Catalog.create_archive_source(%{name: "Lab C-MOVE", root_path: root})
    {:ok, completed} = Scanner.scan_sync(source.id)

    assert completed.status == "completed"
    assert completed.files_discovered == 4
    assert completed.files_indexed == 3
    assert completed.files_quarantined == 1

    stats = Catalog.catalog_stats()
    assert stats.studies == 2
    assert stats.series == 2
    assert stats.instances == 3
    assert stats.ingest_errors == 1

    [err] = Catalog.list_ingest_errors(source.id)
    assert String.ends_with?(err.file_path, "corrupt_file.dcm")

    # Idempotent re-scan does not duplicate records
    {:ok, rescanned} = Scanner.scan_sync(source.id)
    assert rescanned.files_indexed == 3
    assert Catalog.catalog_stats().instances == 3

    # Deleting the archive source prunes orphaned studies and series cleanly on SQLite
    {:ok, _} = Catalog.delete_archive_source(rescanned)
    final_stats = Catalog.catalog_stats()
    assert final_stats.archive_sources == 0
    assert final_stats.studies == 0
    assert final_stats.series == 0
    assert final_stats.instances == 0
  end

  test "enforces strict archive root boundary checks against path traversal" do
    root = DicomFixtures.create_temp_archive!("boundary_test")
    on_exit(fn -> File.rm_rf!(root) end)

    inside = Path.join(root, "sub/file.dcm")
    outside = Path.join(root, "../outside.dcm")

    assert DicomReader.safe_path?(inside, root)
    refute DicomReader.safe_path?(outside, root)
  end
end
