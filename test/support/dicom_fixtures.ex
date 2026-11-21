defmodule Dia.DicomFixtures do
  @moduledoc """
  Deterministic zero-PHI synthetic DICOM Part 10 fixture generator for tests.
  """

  alias Dicom.DataSet

  @explicit_vr_le "1.2.840.10008.1.2.1"
  @mr_sop_class "1.2.840.10008.5.1.4.1.1.4"
  @ct_sop_class "1.2.840.10008.5.1.4.1.1.2"

  def write_synthetic_dcm!(path, attrs \\ %{}) do
    modality = Map.get(attrs, :modality, "MR")
    sop_class = if(modality == "CT", do: @ct_sop_class, else: @mr_sop_class)

    study_uid = Map.get(attrs, :study_uid, Dicom.UID.generate())
    series_uid = Map.get(attrs, :series_uid, Dicom.UID.generate())
    sop_uid = Map.get(attrs, :sop_uid, Dicom.UID.generate())

    rows = Map.get(attrs, :rows, 8)
    cols = Map.get(attrs, :columns, 8)
    pixel_bytes = Map.get(attrs, :pixel_bytes, :binary.copy(<<0x42, 0x00>>, rows * cols))

    ds =
      DataSet.new()
      |> DataSet.put({0x0002, 0x0002}, :UI, sop_class)
      |> DataSet.put({0x0002, 0x0003}, :UI, sop_uid)
      |> DataSet.put({0x0002, 0x0010}, :UI, @explicit_vr_le)
      |> DataSet.put({0x0008, 0x0005}, :CS, "ISO_IR 192")
      |> DataSet.put({0x0008, 0x0016}, :UI, sop_class)
      |> DataSet.put({0x0008, 0x0018}, :UI, sop_uid)
      |> DataSet.put({0x0008, 0x0020}, :DA, Map.get(attrs, :study_date, "20260315"))
      |> DataSet.put({0x0008, 0x0030}, :TM, "101500")
      |> DataSet.put({0x0008, 0x0050}, :SH, Map.get(attrs, :accession_number, "ACC-001"))
      |> DataSet.put({0x0008, 0x0060}, :CS, modality)
      |> DataSet.put(
        {0x0008, 0x0080},
        :LO,
        Map.get(attrs, :institution_name, "Alaska Imaging Lab")
      )
      |> DataSet.put(
        {0x0008, 0x1030},
        :LO,
        Map.get(attrs, :study_description, "Brain Research MRI")
      )
      |> DataSet.put(
        {0x0008, 0x103E},
        :LO,
        Map.get(attrs, :series_description, "T1 MPRAGE Sagittal")
      )
      |> DataSet.put({0x0010, 0x0010}, :PN, Map.get(attrs, :patient_name, "PHANTOM^SYNTHETIC"))
      |> DataSet.put({0x0010, 0x0020}, :LO, Map.get(attrs, :patient_id, "SYN-0001"))
      |> DataSet.put({0x0010, 0x0030}, :DA, "19850101")
      |> DataSet.put({0x0010, 0x0040}, :CS, "O")
      |> DataSet.put({0x0018, 0x0015}, :CS, Map.get(attrs, :body_part, "BRAIN"))
      |> DataSet.put({0x0018, 0x1030}, :LO, Map.get(attrs, :protocol_name, "RESEARCH_T1"))
      |> DataSet.put({0x0020, 0x000D}, :UI, study_uid)
      |> DataSet.put({0x0020, 0x000E}, :UI, series_uid)
      |> DataSet.put({0x0020, 0x0011}, :IS, Map.get(attrs, :series_number, "1"))
      |> DataSet.put({0x0020, 0x0013}, :IS, Map.get(attrs, :instance_number, "1"))
      |> DataSet.put({0x0028, 0x0002}, :US, <<1::little-16>>)
      |> DataSet.put({0x0028, 0x0004}, :CS, "MONOCHROME2")
      |> DataSet.put({0x0028, 0x0010}, :US, <<rows::little-16>>)
      |> DataSet.put({0x0028, 0x0011}, :US, <<cols::little-16>>)
      |> DataSet.put({0x0028, 0x0100}, :US, <<16::little-16>>)
      |> DataSet.put({0x0028, 0x0101}, :US, <<12::little-16>>)
      |> DataSet.put({0x0028, 0x0102}, :US, <<11::little-16>>)
      |> DataSet.put({0x0028, 0x0103}, :US, <<0::little-16>>)
      |> DataSet.put({0x7FE0, 0x0010}, :OW, pixel_bytes)

    File.mkdir_p!(Path.dirname(path))
    :ok = Dicom.write_file(ds, path)

    %{
      path: Path.expand(path),
      study_uid: study_uid,
      series_uid: series_uid,
      sop_uid: sop_uid,
      pixel_bytes: pixel_bytes
    }
  end

  def create_temp_archive!(prefix \\ "dia_test_archive") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end
end
