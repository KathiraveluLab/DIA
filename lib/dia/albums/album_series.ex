defmodule Dia.Albums.AlbumSeries do
  @moduledoc """
  Join record associating a DICOM series with a virtual album without copying files.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "album_series" do
    belongs_to :album, Dia.Albums.Album
    belongs_to :series, Dia.Catalog.Series

    timestamps(type: :utc_datetime)
  end

  def changeset(album_series, attrs) do
    album_series
    |> cast(attrs, [])
    |> unique_constraint([:album_id, :series_id])
  end
end
