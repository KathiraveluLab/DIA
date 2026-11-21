defmodule DiaWeb.ManifestController do
  @moduledoc """
  Downloads reproducible JSON or CSV cohort manifests for a DIA album.
  """
  use DiaWeb, :controller

  alias Dia.Albums

  def export_json(conn, %{"id" => id}) do
    album = Albums.get_album!(id)
    payload = Albums.export_manifest_map(album)
    filename = slugify(album.name) <> "-manifest.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(:ok, Jason.encode!(payload, pretty: true))
  end

  def export_csv(conn, %{"id" => id}) do
    album = Albums.get_album!(id)
    csv = Albums.export_manifest_csv(album)
    filename = slugify(album.name) <> "-manifest.csv"

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(:ok, csv)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "dia-album"
      slug -> slug
    end
  end
end
