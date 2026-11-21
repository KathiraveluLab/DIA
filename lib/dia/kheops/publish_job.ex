defmodule Dia.Kheops.PublishJob do
  @moduledoc """
  Tracks an album publication workflow to a remote Kheops instance via REST and STOW-RS (Mode A).
  Credentials are never persisted in the database.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @valid_statuses ~w(pending running completed partial_failure failed)

  schema "kheops_publish_jobs" do
    field :kheops_base_url, :string
    field :kheops_album_name, :string
    field :kheops_album_id, :string
    field :remote_share_url, :string
    field :deidentify, :boolean, default: true
    field :status, :string, default: "pending"
    field :total_instances, :integer, default: 0
    field :uploaded_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :error_log, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :album, Dia.Albums.Album

    timestamps(type: :utc_datetime)
  end

  def create_changeset(job, attrs) do
    job
    |> cast(attrs, [:kheops_base_url, :kheops_album_name, :deidentify])
    |> update_change(:kheops_base_url, &normalize_url/1)
    |> update_change(:kheops_album_name, &trim_string/1)
    |> validate_required([:kheops_base_url, :kheops_album_name])
    |> validate_http_url(:kheops_base_url)
  end

  def progress_changeset(job, attrs) do
    job
    |> cast(attrs, [
      :kheops_album_id,
      :remote_share_url,
      :status,
      :total_instances,
      :uploaded_count,
      :failed_count,
      :error_log,
      :started_at,
      :completed_at
    ])
    |> validate_inclusion(:status, @valid_statuses)
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp normalize_url(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp normalize_url(value), do: value

  defp validate_http_url(changeset, field) do
    validate_change(changeset, field, fn _, url ->
      case URI.parse(url) do
        %URI{scheme: scheme, host: host}
        when scheme in ["http", "https"] and is_binary(host) and host != "" ->
          []

        _ ->
          [{field, "must be a valid http or https URL"}]
      end
    end)
  end
end
