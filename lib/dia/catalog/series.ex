defmodule Dia.Catalog.Series do
  @moduledoc """
  Indexed DICOM Series-level metadata belonging to a Study.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "series" do
    field :series_instance_uid, :string
    field :modality, :string
    field :body_part_examined, :string
    field :series_description, :string
    field :series_number, :string
    field :protocol_name, :string
    field :instance_count, :integer, default: 0

    belongs_to :study, Dia.Catalog.Study
    has_many :instances, Dia.Catalog.Instance
    has_many :album_series, Dia.Albums.AlbumSeries

    timestamps(type: :utc_datetime)
  end

  def changeset(series, attrs) do
    series
    |> cast(attrs, [
      :series_instance_uid,
      :modality,
      :body_part_examined,
      :series_description,
      :series_number,
      :protocol_name,
      :instance_count
    ])
    |> validate_required([:series_instance_uid])
    |> unique_constraint(:series_instance_uid)
  end
end
