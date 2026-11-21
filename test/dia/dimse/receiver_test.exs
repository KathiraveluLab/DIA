defmodule Dia.Dimse.ReceiverTest do
  use Dia.DataCase, async: false

  alias Dia.{Catalog, DicomFixtures}
  alias Dia.Dimse.Receiver

  @explicit_vr_le "1.2.840.10008.1.2.1"
  @mr_sop_class "1.2.840.10008.5.1.4.1.1.4"

  test "accepts C-ECHO and C-STORE pushes over TCP, writes Part 10 files, and indexes automatically" do
    root = DicomFixtures.create_temp_archive!("dimse_scp_test")

    on_exit(fn ->
      Receiver.stop_scp()
      File.rm_rf!(root)
    end)

    {:ok, source} = Catalog.create_archive_source(%{name: "DIMSE Dropzone", root_path: root})
    port = 11_200 + rem(System.unique_integer([:positive]), 2000)

    {:ok, status} =
      Receiver.start_scp(
        port: port,
        ae_title: "DIA_TEST_SCP",
        archive_source_id: source.id
      )

    assert status.running
    assert status.port == port

    # Build a synthetic DICOM dataset binary (without Part 10 header, as sent over DIMSE C-STORE)
    tmp_dcm = Path.join(System.tmp_dir!(), "scu_push_#{System.unique_integer([:positive])}.dcm")
    on_exit(fn -> File.rm(tmp_dcm) end)

    fixture =
      DicomFixtures.write_synthetic_dcm!(tmp_dcm, %{
        study_uid: "1.2.826.0.1.3680043.8.498.7701",
        series_uid: "1.2.826.0.1.3680043.8.498.7701.1",
        sop_uid: "1.2.826.0.1.3680043.8.498.7701.1.1",
        modality: "MR",
        body_part: "BRAIN",
        study_description: "DIMSE C-MOVE Push Study",
        series_description: "Live C-STORE Series"
      })

    {:ok, ds} = Dicom.parse_file(fixture.path)
    {:ok, raw_dataset} = Dicom.write_data_set(ds, @explicit_vr_le)

    {:ok, :done} =
      Dimse.with_connection(
        "127.0.0.1",
        port,
        [
          calling_ae: "PACS_SCU",
          called_ae: "DIA_TEST_SCP",
          abstract_syntaxes: ["1.2.840.10008.1.1", @mr_sop_class],
          transfer_syntaxes: [@explicit_vr_le]
        ],
        fn assoc ->
          assert :ok == Dimse.echo(assoc)
          assert :ok == Dimse.store(assoc, @mr_sop_class, fixture.sop_uid, raw_dataset)
          :done
        end
      )

    # Synchronize with Receiver GenServer state without Process.sleep
    _ = :sys.get_state(Receiver)
    updated_status = Receiver.status()
    assert updated_status.received_count == 1
    assert updated_status.last_sop_uid == fixture.sop_uid

    # Verify automatic SQLite indexing made the pushed series immediately searchable
    results = Catalog.search_series(%{"q" => "DIMSE C-MOVE Push Study"})
    assert length(results) == 1
    assert hd(results).series_description == "Live C-STORE Series"

    {:ok, stopped} = Receiver.stop_scp()
    refute stopped.running
  end
end
