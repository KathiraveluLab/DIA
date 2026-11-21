defmodule Dia.Catalog.IngestError do
  @moduledoc """
  Records a malformed or unreadable file quarantined during local archive indexing.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "ingest_errors" do
    field :file_path, :string
    field :error_reason, :string

    belongs_to :archive_source, Dia.Catalog.ArchiveSource

    timestamps(type: :utc_datetime)
  end

  def changeset(ingest_error, attrs) do
    ingest_error
    |> cast(attrs, [:file_path, :error_reason])
    |> validate_required([:file_path, :error_reason])
  end
end
