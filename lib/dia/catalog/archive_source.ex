defmodule Dia.Catalog.ArchiveSource do
  @moduledoc """
  Represents a local filesystem directory containing DICOM files retrieved from a PACS.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(idle scanning completed error)

  schema "archive_sources" do
    field :name, :string
    field :root_path, :string
    field :status, :string, default: "idle"
    field :files_discovered, :integer, default: 0
    field :files_indexed, :integer, default: 0
    field :files_quarantined, :integer, default: 0
    field :last_scanned_at, :utc_datetime
    field :last_error, :string

    has_many :instances, Dia.Catalog.Instance
    has_many :ingest_errors, Dia.Catalog.IngestError

    timestamps(type: :utc_datetime)
  end

  def changeset(source, attrs) do
    source
    |> cast(attrs, [:name, :root_path])
    |> update_change(:name, &trim_string/1)
    |> update_change(:root_path, &normalize_root_path/1)
    |> validate_required([:name, :root_path])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_directory_exists()
    |> unique_constraint(:root_path)
  end

  def scan_status_changeset(source, attrs) do
    source
    |> cast(attrs, [
      :status,
      :files_discovered,
      :files_indexed,
      :files_quarantined,
      :last_scanned_at,
      :last_error
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp normalize_root_path(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> ""
      path -> Path.expand(path)
    end
  end

  defp normalize_root_path(value), do: value

  defp validate_directory_exists(changeset) do
    case get_field(changeset, :root_path) do
      path when is_binary(path) and path != "" ->
        if File.dir?(path) do
          changeset
        else
          add_error(changeset, :root_path, "directory does not exist on this host")
        end

      _ ->
        changeset
    end
  end
end
