defmodule Dia.Albums.Album do
  @moduledoc """
  Represents a zero-copy logical collection of DICOM series selected from local archives.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "albums" do
    field :name, :string
    field :description, :string
    field :query_filter_json, :string
    field :deidentify_default, :boolean, default: false

    has_many :album_series, Dia.Albums.AlbumSeries
    many_to_many :series, Dia.Catalog.Series, join_through: Dia.Albums.AlbumSeries
    has_many :share_links, Dia.Albums.ShareLink
    has_many :kheops_publish_jobs, Dia.Kheops.PublishJob

    timestamps(type: :utc_datetime)
  end

  def changeset(album, attrs) do
    album
    |> cast(attrs, [:name, :description, :query_filter_json, :deidentify_default])
    |> update_change(:name, &trim_string/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 140)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
