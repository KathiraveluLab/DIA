defmodule Dia.Catalog.Instance do
  @moduledoc """
  Indexed DICOM SOP Instance pointing to a locally stored Part 10 file.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "instances" do
    field :sop_instance_uid, :string
    field :file_path, :string
    field :sop_class_uid, :string
    field :transfer_syntax_uid, :string
    field :instance_number, :string
    field :rows, :integer
    field :columns, :integer
    field :number_of_frames, :integer, default: 1
    field :file_size_bytes, :integer, default: 0
    field :metadata_json, :string

    belongs_to :series, Dia.Catalog.Series
    belongs_to :study, Dia.Catalog.Study
    belongs_to :archive_source, Dia.Catalog.ArchiveSource

    timestamps(type: :utc_datetime)
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [
      :sop_instance_uid,
      :file_path,
      :sop_class_uid,
      :transfer_syntax_uid,
      :instance_number,
      :rows,
      :columns,
      :number_of_frames,
      :file_size_bytes,
      :metadata_json
    ])
    |> validate_required([:sop_instance_uid, :file_path])
    |> unique_constraint(:sop_instance_uid)
    |> unique_constraint(:file_path)
  end
end
