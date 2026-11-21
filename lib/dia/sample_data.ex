defmodule Dia.SampleData do
  @moduledoc """
  Generates a zero-PHI synthetic multi-modal DICOM Part 10 research archive and
  populates sample albums and virtual OHIF share links for interactive evaluation.
  """

  alias Dia.{Albums, Catalog}
  alias Dia.Ingest.Scanner
  alias Dicom.DataSet

  @explicit_vr_le "1.2.840.10008.1.2.1"
  @mr_sop_class "1.2.840.10008.5.1.4.1.1.4"
  @ct_sop_class "1.2.840.10008.5.1.4.1.1.2"
  @pt_sop_class "1.2.840.10008.5.1.4.1.1.128"

  def default_dir do
    Path.expand("priv/sample_dicoms", File.cwd!())
  end

  @doc """
  Generates synthetic DICOM files in `dir`, registers the local archive source,
  indexes it concurrently, and creates sample zero-copy albums with Mode B share links.
  """
  def seed!(dir \\ default_dir()) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    studies = cohort_spec()

    Enum.each(studies, fn study ->
      Enum.each(study.series, fn ser ->
        for idx <- 1..ser.slices do
          sop_uid = "#{ser.series_uid}.#{idx}"
          rel_path = Path.join([study.folder, ser.folder, "slice_#{pad(idx)}.dcm"])
          full_path = Path.join(dir, rel_path)
          write_synthetic_instance!(full_path, study, ser, sop_uid, idx)
        end
      end)
    end)

    # Write one intentionally malformed file to demonstrate fault-isolated quarantine
    File.write!(
      Path.join(dir, "corrupt_truncated_header.dcm"),
      "CORRUPT_NOT_A_VALID_DICOM_PART10_STREAM"
    )

    source = ensure_archive_source!("Sample C-MOVE Research Cohort", dir)
    {:ok, scanned_source} = Scanner.scan_sync(source.id)

    seed_sample_albums!()

    {:ok, scanned_source}
  end

  defp ensure_archive_source!(name, dir) do
    expanded = Path.expand(dir)

    case Catalog.list_archive_sources() |> Enum.find(&(&1.root_path == expanded)) do
      nil ->
        {:ok, source} = Catalog.create_archive_source(%{name: name, root_path: expanded})
        source

      existing ->
        existing
    end
  end

  defp seed_sample_albums! do
    existing_names = Albums.list_albums() |> Enum.map(& &1.name) |> MapSet.new()

    if not MapSet.member?(existing_names, "Brain Glioma MR Cohort") do
      brain_mr = Catalog.search_series(%{"modality" => "MR", "body_part" => "BRAIN"})

      if brain_mr != [] do
        {:ok, album} =
          Albums.create_album(
            %{
              "name" => "Brain Glioma MR Cohort",
              "description" =>
                "Multi-sequence synthetic brain MRI subset curated from local C-MOVE archive for collaborator review.",
              "query_filter_json" => Jason.encode!(%{"modality" => "MR", "body_part" => "BRAIN"}),
              "deidentify_default" => true
            },
            Enum.map(brain_mr, & &1.id)
          )

        {:ok, _} =
          Albums.create_share_link(album, %{
            "label" => "OHIF De-Identified Collaborator Link",
            "deidentify" => true,
            "expires_at" => DateTime.utc_now(:second) |> DateTime.add(7 * 86_400, :second)
          })

        {:ok, _} =
          Albums.create_share_link(album, %{
            "label" => "Internal Lab Review Link",
            "deidentify" => false,
            "expires_at" => DateTime.utc_now(:second) |> DateTime.add(30 * 86_400, :second)
          })
      end
    end

    if not MapSet.member?(existing_names, "Thoracic CT Screening Subset") do
      chest_ct = Catalog.search_series(%{"modality" => "CT", "body_part" => "CHEST"})

      if chest_ct != [] do
        {:ok, album} =
          Albums.create_album(
            %{
              "name" => "Thoracic CT Screening Subset",
              "description" =>
                "High-resolution lung and mediastinum CT series exported without disk duplication.",
              "query_filter_json" => Jason.encode!(%{"modality" => "CT", "body_part" => "CHEST"}),
              "deidentify_default" => false
            },
            Enum.map(chest_ct, & &1.id)
          )

        {:ok, _} =
          Albums.create_share_link(album, %{
            "label" => "Thoracic Review OHIF Endpoint",
            "deidentify" => true
          })
      end
    end

    :ok
  end

  defp write_synthetic_instance!(path, study, ser, sop_uid, idx) do
    sop_class = sop_class_for(ser.modality)
    rows = 64
    cols = 64
    pixels = synthetic_phantom_pixels(rows, cols, idx)

    ds =
      DataSet.new()
      |> DataSet.put({0x0002, 0x0002}, :UI, sop_class)
      |> DataSet.put({0x0002, 0x0003}, :UI, sop_uid)
      |> DataSet.put({0x0002, 0x0010}, :UI, @explicit_vr_le)
      |> DataSet.put({0x0008, 0x0005}, :CS, "ISO_IR 192")
      |> DataSet.put({0x0008, 0x0016}, :UI, sop_class)
      |> DataSet.put({0x0008, 0x0018}, :UI, sop_uid)
      |> DataSet.put({0x0008, 0x0020}, :DA, study.study_date)
      |> DataSet.put({0x0008, 0x0030}, :TM, "093000")
      |> DataSet.put({0x0008, 0x0050}, :SH, study.accession)
      |> DataSet.put({0x0008, 0x0060}, :CS, ser.modality)
      |> DataSet.put({0x0008, 0x0080}, :LO, study.institution)
      |> DataSet.put({0x0008, 0x1030}, :LO, study.study_description)
      |> DataSet.put({0x0008, 0x103E}, :LO, ser.series_description)
      |> DataSet.put({0x0010, 0x0010}, :PN, study.patient_name)
      |> DataSet.put({0x0010, 0x0020}, :LO, study.patient_id)
      |> DataSet.put({0x0010, 0x0030}, :DA, "19800101")
      |> DataSet.put({0x0010, 0x0040}, :CS, "O")
      |> DataSet.put({0x0018, 0x0015}, :CS, ser.body_part)
      |> DataSet.put({0x0018, 0x1030}, :LO, ser.protocol)
      |> DataSet.put({0x0020, 0x000D}, :UI, study.study_uid)
      |> DataSet.put({0x0020, 0x000E}, :UI, ser.series_uid)
      |> DataSet.put({0x0020, 0x0011}, :IS, ser.series_number)
      |> DataSet.put({0x0020, 0x0013}, :IS, Integer.to_string(idx))
      |> DataSet.put({0x0028, 0x0002}, :US, <<1::little-16>>)
      |> DataSet.put({0x0028, 0x0004}, :CS, "MONOCHROME2")
      |> DataSet.put({0x0028, 0x0010}, :US, <<rows::little-16>>)
      |> DataSet.put({0x0028, 0x0011}, :US, <<cols::little-16>>)
      |> DataSet.put({0x0028, 0x0100}, :US, <<16::little-16>>)
      |> DataSet.put({0x0028, 0x0101}, :US, <<12::little-16>>)
      |> DataSet.put({0x0028, 0x0102}, :US, <<11::little-16>>)
      |> DataSet.put({0x0028, 0x0103}, :US, <<0::little-16>>)
      |> DataSet.put({0x7FE0, 0x0010}, :OW, pixels)

    File.mkdir_p!(Path.dirname(path))
    :ok = Dicom.write_file(ds, path)
  end

  defp synthetic_phantom_pixels(rows, cols, slice_idx) do
    cx = div(cols, 2)
    cy = div(rows, 2)
    radius_sq = div(rows, 3) * div(rows, 3)

    for y <- 0..(rows - 1), x <- 0..(cols - 1), into: <<>> do
      dx = x - cx
      dy = y - cy
      dist_sq = dx * dx + dy * dy

      intensity =
        if dist_sq <= radius_sq do
          min(4095, 600 + slice_idx * 140 + rem((x + y) * 17, 400))
        else
          40
        end

      <<intensity::little-16>>
    end
  end

  defp sop_class_for("CT"), do: @ct_sop_class
  defp sop_class_for("PT"), do: @pt_sop_class
  defp sop_class_for(_), do: @mr_sop_class

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  defp cohort_spec do
    [
      %{
        folder: "study_01_brain_mr",
        study_uid: "1.2.826.0.1.3680043.8.498.9001",
        patient_id: "SYN-NEURO-001",
        patient_name: "PHANTOM^NEURO_ONE",
        study_date: "20260210",
        accession: "ACC-9001",
        institution: "Alaska Neuroimaging Center",
        study_description: "Glioma Baseline Brain MRI",
        series: [
          %{
            folder: "ser_01_t1",
            series_uid: "1.2.826.0.1.3680043.8.498.9001.1",
            series_number: "1",
            modality: "MR",
            body_part: "BRAIN",
            series_description: "T1 MPRAGE Sagittal 1mm",
            protocol: "NEURO_T1_3D",
            slices: 3
          },
          %{
            folder: "ser_02_flair",
            series_uid: "1.2.826.0.1.3680043.8.498.9001.2",
            series_number: "2",
            modality: "MR",
            body_part: "BRAIN",
            series_description: "T2 FLAIR Axial",
            protocol: "NEURO_FLAIR",
            slices: 3
          }
        ]
      },
      %{
        folder: "study_02_brain_mr_followup",
        study_uid: "1.2.826.0.1.3680043.8.498.9002",
        patient_id: "SYN-NEURO-002",
        patient_name: "PHANTOM^NEURO_TWO",
        study_date: "20260318",
        accession: "ACC-9002",
        institution: "Alaska Neuroimaging Center",
        study_description: "Glioma Post-Treatment MRI",
        series: [
          %{
            folder: "ser_01_t1c",
            series_uid: "1.2.826.0.1.3680043.8.498.9002.1",
            series_number: "1",
            modality: "MR",
            body_part: "BRAIN",
            series_description: "T1 Post-Contrast Axial",
            protocol: "NEURO_T1C",
            slices: 3
          },
          %{
            folder: "ser_02_dwi",
            series_uid: "1.2.826.0.1.3680043.8.498.9002.2",
            series_number: "2",
            modality: "MR",
            body_part: "BRAIN",
            series_description: "DWI Trace b1000",
            protocol: "NEURO_DWI",
            slices: 3
          }
        ]
      },
      %{
        folder: "study_03_chest_ct",
        study_uid: "1.2.826.0.1.3680043.8.498.9003",
        patient_id: "SYN-THORAX-003",
        patient_name: "PHANTOM^THORAX_THREE",
        study_date: "20260405",
        accession: "ACC-9003",
        institution: "Pacific Thoracic Institute",
        study_description: "Low-Dose Chest CT Screening",
        series: [
          %{
            folder: "ser_01_lung",
            series_uid: "1.2.826.0.1.3680043.8.498.9003.1",
            series_number: "1",
            modality: "CT",
            body_part: "CHEST",
            series_description: "Lung Window 1.0mm",
            protocol: "LDCT_LUNG",
            slices: 3
          },
          %{
            folder: "ser_02_mediastinum",
            series_uid: "1.2.826.0.1.3680043.8.498.9003.2",
            series_number: "2",
            modality: "CT",
            body_part: "CHEST",
            series_description: "Mediastinum Soft Tissue",
            protocol: "LDCT_MEDIASTINUM",
            slices: 3
          }
        ]
      },
      %{
        folder: "study_04_abdomen_ct",
        study_uid: "1.2.826.0.1.3680043.8.498.9004",
        patient_id: "SYN-ABD-004",
        patient_name: "PHANTOM^ABDOMEN_FOUR",
        study_date: "20260512",
        accession: "ACC-9004",
        institution: "Pacific Thoracic Institute",
        study_description: "Abdominal Portal Venous CT",
        series: [
          %{
            folder: "ser_01_pv",
            series_uid: "1.2.826.0.1.3680043.8.498.9004.1",
            series_number: "1",
            modality: "CT",
            body_part: "ABDOMEN",
            series_description: "Portal Venous 2.5mm",
            protocol: "ABD_PV",
            slices: 4
          }
        ]
      },
      %{
        folder: "study_05_pet_mr_brain",
        study_uid: "1.2.826.0.1.3680043.8.498.9005",
        patient_id: "SYN-ONC-005",
        patient_name: "PHANTOM^ONCOLOGY_FIVE",
        study_date: "20260602",
        accession: "ACC-9005",
        institution: "Arctic Oncology Lab",
        study_description: "Hybrid PET-MR Brain Metabolism",
        series: [
          %{
            folder: "ser_01_pet",
            series_uid: "1.2.826.0.1.3680043.8.498.9005.1",
            series_number: "1",
            modality: "PT",
            body_part: "BRAIN",
            series_description: "FDG-PET Attenuation Corrected",
            protocol: "ONC_FDG_BRAIN",
            slices: 2
          },
          %{
            folder: "ser_02_mr",
            series_uid: "1.2.826.0.1.3680043.8.498.9005.2",
            series_number: "2",
            modality: "MR",
            body_part: "BRAIN",
            series_description: "T1 Structural Reference",
            protocol: "ONC_T1_REF",
            slices: 2
          }
        ]
      },
      %{
        folder: "study_06_head_ct",
        study_uid: "1.2.826.0.1.3680043.8.498.9006",
        patient_id: "SYN-HEAD-006",
        patient_name: "PHANTOM^TRAUMA_SIX",
        study_date: "20260719",
        accession: "ACC-9006",
        institution: "Arctic Oncology Lab",
        study_description: "Non-Contrast Head CT",
        series: [
          %{
            folder: "ser_01_head",
            series_uid: "1.2.826.0.1.3680043.8.498.9006.1",
            series_number: "1",
            modality: "CT",
            body_part: "HEAD",
            series_description: "Axial Brain 5mm",
            protocol: "HEAD_NCCT",
            slices: 4
          }
        ]
      }
    ]
  end
end
