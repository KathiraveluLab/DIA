defmodule Dia.Catalog.Study do
  @moduledoc """
  Indexed DICOM Study-level metadata aggregated across one or more series.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "studies" do
    field :study_instance_uid, :string
    field :patient_id, :string
    field :patient_name, :string
    field :patient_sex, :string
    field :patient_birth_date, :string
    field :study_date, :string
    field :study_time, :string
    field :study_description, :string
    field :accession_number, :string
    field :institution_name, :string
    field :modalities, :string, default: ""
    field :series_count, :integer, default: 0
    field :instance_count, :integer, default: 0

    has_many :series, Dia.Catalog.Series
    has_many :instances, Dia.Catalog.Instance

    timestamps(type: :utc_datetime)
  end

  def changeset(study, attrs) do
    study
    |> cast(attrs, [
      :study_instance_uid,
      :patient_id,
      :patient_name,
      :patient_sex,
      :patient_birth_date,
      :study_date,
      :study_time,
      :study_description,
      :accession_number,
      :institution_name,
      :modalities,
      :series_count,
      :instance_count
    ])
    |> validate_required([:study_instance_uid])
    |> unique_constraint(:study_instance_uid)
  end
end
