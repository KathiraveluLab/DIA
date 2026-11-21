defmodule Dia.Albums.ShareLink do
  @moduledoc """
  Capability-scoped virtual DICOMweb share link for an album (Mode B: OHIF Viewer integration).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "share_links" do
    field :label, :string
    field :token, :string
    field :deidentify, :boolean, default: false
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :access_count, :integer, default: 0
    field :last_accessed_at, :utc_datetime

    belongs_to :album, Dia.Albums.Album

    timestamps(type: :utc_datetime)
  end

  def changeset(share_link, attrs) do
    share_link
    |> cast(attrs, [:label, :deidentify, :expires_at])
    |> update_change(:label, &trim_string/1)
    |> validate_required([:label])
    |> validate_length(:label, min: 1, max: 120)
    |> unique_constraint(:token)
  end

  def active?(%__MODULE__{revoked_at: revoked_at, expires_at: expires_at}) do
    not_revoked? = is_nil(revoked_at)

    not_expired? =
      case expires_at do
        nil -> true
        %DateTime{} = dt -> DateTime.compare(dt, DateTime.utc_now()) == :gt
      end

    not_revoked? and not_expired?
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value
end
