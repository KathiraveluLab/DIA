defmodule Dia.Repo.Migrations.CreateDiaTables do
  use Ecto.Migration

  def change do
    create table(:archive_sources) do
      add :name, :string, null: false
      add :root_path, :string, null: false
      add :status, :string, null: false, default: "idle"
      add :files_discovered, :integer, null: false, default: 0
      add :files_indexed, :integer, null: false, default: 0
      add :files_quarantined, :integer, null: false, default: 0
      add :last_scanned_at, :utc_datetime
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:archive_sources, [:root_path])

    create table(:studies) do
      add :study_instance_uid, :string, null: false
      add :patient_id, :string
      add :patient_name, :string
      add :patient_sex, :string
      add :patient_birth_date, :string
      add :study_date, :string
      add :study_time, :string
      add :study_description, :string
      add :accession_number, :string
      add :institution_name, :string
      add :modalities, :string, null: false, default: ""
      add :series_count, :integer, null: false, default: 0
      add :instance_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:studies, [:study_instance_uid])
    create index(:studies, [:study_date])
    create index(:studies, [:patient_id])

    create table(:series) do
      add :series_instance_uid, :string, null: false
      add :study_id, references(:studies, on_delete: :delete_all), null: false
      add :modality, :string
      add :body_part_examined, :string
      add :series_description, :string
      add :series_number, :string
      add :protocol_name, :string
      add :instance_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:series, [:series_instance_uid])
    create index(:series, [:study_id])
    create index(:series, [:modality])
    create index(:series, [:body_part_examined])

    create table(:instances) do
      add :sop_instance_uid, :string, null: false
      add :series_id, references(:series, on_delete: :delete_all), null: false
      add :study_id, references(:studies, on_delete: :delete_all), null: false
      add :archive_source_id, references(:archive_sources, on_delete: :delete_all), null: false
      add :file_path, :string, null: false
      add :sop_class_uid, :string
      add :transfer_syntax_uid, :string
      add :instance_number, :string
      add :rows, :integer
      add :columns, :integer
      add :number_of_frames, :integer, null: false, default: 1
      add :file_size_bytes, :integer, null: false, default: 0
      add :metadata_json, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:instances, [:sop_instance_uid])
    create unique_index(:instances, [:file_path])
    create index(:instances, [:series_id])
    create index(:instances, [:study_id])
    create index(:instances, [:archive_source_id])

    create table(:ingest_errors) do
      add :archive_source_id, references(:archive_sources, on_delete: :delete_all), null: false
      add :file_path, :string, null: false
      add :error_reason, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ingest_errors, [:archive_source_id])

    create table(:albums) do
      add :name, :string, null: false
      add :description, :text
      add :query_filter_json, :text
      add :deidentify_default, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:albums, [:name])

    create table(:album_series) do
      add :album_id, references(:albums, on_delete: :delete_all), null: false
      add :series_id, references(:series, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:album_series, [:album_id, :series_id])
    create index(:album_series, [:series_id])

    create table(:share_links) do
      add :album_id, references(:albums, on_delete: :delete_all), null: false
      add :label, :string, null: false
      add :token, :string, null: false
      add :deidentify, :boolean, null: false, default: false
      add :expires_at, :utc_datetime
      add :revoked_at, :utc_datetime
      add :access_count, :integer, null: false, default: 0
      add :last_accessed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:share_links, [:token])
    create index(:share_links, [:album_id])

    create table(:kheops_publish_jobs) do
      add :album_id, references(:albums, on_delete: :delete_all), null: false
      add :kheops_base_url, :string, null: false
      add :kheops_album_name, :string, null: false
      add :kheops_album_id, :string
      add :remote_share_url, :string
      add :deidentify, :boolean, null: false, default: true
      add :status, :string, null: false, default: "pending"
      add :total_instances, :integer, null: false, default: 0
      add :uploaded_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      add :error_log, :text
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:kheops_publish_jobs, [:album_id])
  end
end
