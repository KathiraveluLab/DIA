defmodule Dia.Kheops do
  @moduledoc """
  Persistence and query helpers for Kheops publication jobs (Mode A).
  """

  import Ecto.Query

  alias Dia.Albums.Album
  alias Dia.Kheops.PublishJob
  alias Dia.Repo

  def change_publish_job(%PublishJob{} = job, attrs \\ %{}) do
    PublishJob.create_changeset(job, attrs)
  end

  def create_publish_job(%Album{} = album, attrs) do
    %PublishJob{album_id: album.id}
    |> PublishJob.create_changeset(attrs)
    |> Repo.insert()
  end

  def update_publish_job(%PublishJob{} = job, attrs) do
    job
    |> PublishJob.progress_changeset(attrs)
    |> Repo.update()
  end

  def list_publish_jobs(album_id) do
    from(j in PublishJob,
      where: j.album_id == ^album_id,
      order_by: [desc: j.inserted_at]
    )
    |> Repo.all()
  end

  def get_publish_job!(id), do: Repo.get!(PublishJob, id)
end
