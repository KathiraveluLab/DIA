# Reproducible performance benchmark for DIA.
# Run with: mix run priv/repo/benchmark.exs
#
# Measures:
#   1. Sequential (1 worker) vs. Concurrent BEAM ingestion throughput across 100, 500, and 1,000
#      synthetic DICOM Part 10 files (with 2% injected corrupt files to measure fault isolation).
#   2. Faceted SQLite metadata query latency (p50, p95, mean).
#   3. Zero-copy album creation latency and disk savings vs. physical file duplication.
#   4. Mode B WADO-RS metadata and frame extraction latency (raw vs. PS3.15 de-identified).
#   5. Mode A Kheops STOW-RS publication throughput with PS3.15 album-consistent UID remapping.

Logger.configure(level: :warning)

alias Dia.{Albums, Catalog}
alias Dia.Ingest.{DicomReader, Scanner}
alias Dia.Kheops.Publisher
alias Dicom.DataSet

defmodule Dia.BenchHelper do
  @explicit_vr_le "1.2.840.10008.1.2.1"
  @mr_sop_class "1.2.840.10008.5.1.4.1.1.4"
  @ct_sop_class "1.2.840.10008.5.1.4.1.1.2"

  def generate_corpus!(dir, total_files, corrupt_ratio \\ 0.02) do
    File.rm_rf!(dir)
    File.mkdir_p!(dir)

    corrupt_count = max(1, round(total_files * corrupt_ratio))
    valid_count = total_files - corrupt_count
    pixel_bytes = :binary.copy(<<0x55, 0x01>>, 64 * 64)

    for i <- 1..valid_count do
      study_idx = div(i - 1, 20) + 1
      series_idx = div(rem(i - 1, 20), 10) + 1
      modality = if(rem(study_idx, 2) == 0, do: "CT", else: "MR")
      body_part = if(modality == "CT", do: "CHEST", else: "BRAIN")
      sop_class = if(modality == "CT", do: @ct_sop_class, else: @mr_sop_class)

      study_uid = "1.2.826.0.1.3680043.8.498.8000.#{total_files}.#{study_idx}"
      series_uid = "#{study_uid}.#{series_idx}"
      sop_uid = "#{series_uid}.#{i}"

      ds =
        DataSet.new()
        |> DataSet.put({0x0002, 0x0002}, :UI, sop_class)
        |> DataSet.put({0x0002, 0x0003}, :UI, sop_uid)
        |> DataSet.put({0x0002, 0x0010}, :UI, @explicit_vr_le)
        |> DataSet.put({0x0008, 0x0005}, :CS, "ISO_IR 192")
        |> DataSet.put({0x0008, 0x0016}, :UI, sop_class)
        |> DataSet.put({0x0008, 0x0018}, :UI, sop_uid)
        |> DataSet.put({0x0008, 0x0020}, :DA, "202604#{String.pad_leading(Integer.to_string(rem(study_idx, 28) + 1), 2, "0")}")
        |> DataSet.put({0x0008, 0x0060}, :CS, modality)
        |> DataSet.put({0x0008, 0x0080}, :LO, "Benchmark Center #{rem(study_idx, 3) + 1}")
        |> DataSet.put({0x0008, 0x1030}, :LO, "Benchmark #{body_part} #{modality}")
        |> DataSet.put({0x0008, 0x103E}, :LO, "Series #{series_idx} #{modality}")
        |> DataSet.put({0x0010, 0x0010}, :PN, "PHANTOM^BENCH_#{study_idx}")
        |> DataSet.put({0x0010, 0x0020}, :LO, "BENCH-#{study_idx}")
        |> DataSet.put({0x0018, 0x0015}, :CS, body_part)
        |> DataSet.put({0x0020, 0x000D}, :UI, study_uid)
        |> DataSet.put({0x0020, 0x000E}, :UI, series_uid)
        |> DataSet.put({0x0020, 0x0011}, :IS, Integer.to_string(series_idx))
        |> DataSet.put({0x0020, 0x0013}, :IS, Integer.to_string(i))
        |> DataSet.put({0x0028, 0x0002}, :US, <<1::little-16>>)
        |> DataSet.put({0x0028, 0x0004}, :CS, "MONOCHROME2")
        |> DataSet.put({0x0028, 0x0010}, :US, <<64::little-16>>)
        |> DataSet.put({0x0028, 0x0011}, :US, <<64::little-16>>)
        |> DataSet.put({0x0028, 0x0100}, :US, <<16::little-16>>)
        |> DataSet.put({0x0028, 0x0101}, :US, <<12::little-16>>)
        |> DataSet.put({0x0028, 0x0102}, :US, <<11::little-16>>)
        |> DataSet.put({0x0028, 0x0103}, :US, <<0::little-16>>)
        |> DataSet.put({0x7FE0, 0x0010}, :OW, pixel_bytes)

      path = Path.join([dir, "study_#{study_idx}", "inst_#{i}.dcm"])
      File.mkdir_p!(Path.dirname(path))
      :ok = Dicom.write_file(ds, path)
    end

    for c <- 1..corrupt_count do
      File.write!(Path.join(dir, "corrupt_#{c}.dcm"), "INVALID_BENCHMARK_HEADER_#{c}")
    end

    bytes =
      list_dcm_files(dir)
      |> Enum.reduce(0, fn p, acc -> acc + File.stat!(p).size end)

    %{valid: valid_count, corrupt: corrupt_count, total_bytes: bytes}
  end

  def list_dcm_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          full = Path.join(dir, entry)

          cond do
            File.dir?(full) -> list_dcm_files(full)
            String.ends_with?(String.downcase(entry), ".dcm") -> [full]
            true -> []
          end
        end)

      _ ->
        []
    end
  end

  def time_ms(fun) do
    t0 = System.monotonic_time(:microsecond)
    res = fun.()
    t1 = System.monotonic_time(:microsecond)
    {(t1 - t0) / 1000.0, res}
  end

  def percentile(sorted, p) do
    n = length(sorted)
    idx = min(n - 1, max(0, trunc(Float.ceil(p * n)) - 1))
    Enum.at(sorted, idx)
  end

  def sequential_parse_only(dir) do
    files = list_dcm_files(dir)

    Enum.reduce(files, {0, 0}, fn path, {ok_acc, err_acc} ->
      case DicomReader.read_metadata(path) do
        {:ok, _} -> {ok_acc + 1, err_acc}
        {:error, _} -> {ok_acc, err_acc + 1}
      end
    end)
  end

  def concurrent_parse_only(dir, concurrency) do
    files = list_dcm_files(dir)

    files
    |> Task.async_stream(&DicomReader.read_metadata/1,
      max_concurrency: concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Enum.reduce({0, 0}, fn
      {:ok, {:ok, _}}, {ok_acc, err_acc} -> {ok_acc + 1, err_acc}
      _, {ok_acc, err_acc} -> {ok_acc, err_acc + 1}
    end)
  end
end

bench_root = Path.join(System.tmp_dir!(), "dia_bench_#{System.unique_integer([:positive])}")
File.mkdir_p!(bench_root)

schedulers = System.schedulers_online()
IO.puts("=== DIA Standalone Benchmark (Elixir #{System.version()}, OTP #{System.otp_release()}, #{schedulers} schedulers) ===")

# 1. Ingestion scaling across 100, 500, and 1,000 files
results =
  for n <- [100, 500, 1000] do
    dir = Path.join(bench_root, "corpus_#{n}")
    corpus = Dia.BenchHelper.generate_corpus!(dir, n)

    {seq_parse_ms, _} = Dia.BenchHelper.time_ms(fn -> Dia.BenchHelper.sequential_parse_only(dir) end)

    {par_parse_ms, _} =
      Dia.BenchHelper.time_ms(fn -> Dia.BenchHelper.concurrent_parse_only(dir, schedulers) end)

    {:ok, source} = Catalog.create_archive_source(%{name: "Bench #{n}", root_path: dir})
    {full_scan_ms, {:ok, scanned}} = Dia.BenchHelper.time_ms(fn -> Scanner.scan_sync(source.id) end)

    # Measure faceted SQLite query latency over 50 iterations
    query_times =
      for _ <- 1..50 do
        {ms, _} =
          Dia.BenchHelper.time_ms(fn ->
            Catalog.search_series(%{"modality" => "MR", "body_part" => "BRAIN"})
          end)

        ms
      end
      |> Enum.sort()

    row = %{
      n: n,
      valid: scanned.files_indexed,
      quarantined: scanned.files_quarantined,
      corpus_mb: Float.round(corpus.total_bytes / 1_048_576, 2),
      seq_parse_ms: Float.round(seq_parse_ms, 2),
      par_parse_ms: Float.round(par_parse_ms, 2),
      parse_speedup: Float.round(seq_parse_ms / max(par_parse_ms, 0.01), 2),
      full_scan_ms: Float.round(full_scan_ms, 2),
      full_throughput_fps: Float.round(n / (full_scan_ms / 1000.0), 1),
      query_p50_ms: Float.round(Dia.BenchHelper.percentile(query_times, 0.50), 3),
      query_p95_ms: Float.round(Dia.BenchHelper.percentile(query_times, 0.95), 3)
    }

    IO.puts("Corpus #{n}: #{Jason.encode!(row)}")
    {source, row}
  end

# 2. Zero-copy album creation, Mode B metadata/frame serving, and Mode A Kheops STOW-RS publish on the 1,000-file corpus
{source_1000, _} = List.last(results)
mr_series = Catalog.search_series(%{"modality" => "MR", "archive_source_id" => source_1000.id})
selected_ids = Enum.map(mr_series, & &1.id)

{album_ms, {:ok, album}} =
  Dia.BenchHelper.time_ms(fn ->
    Albums.create_album(
      %{"name" => "Benchmark MR Album", "deidentify_default" => true},
      selected_ids
    )
  end)

album_instances = Albums.list_album_instances(album)
album_bytes = Enum.reduce(album_instances, 0, fn i, acc -> acc + i.file_size_bytes end)

# Compare against physical copy baseline (rclone/local copy equivalent)
copy_dir = Path.join(bench_root, "physical_copy")
File.mkdir_p!(copy_dir)

{copy_ms, _} =
  Dia.BenchHelper.time_ms(fn ->
    Enum.each(album_instances, fn inst ->
      File.cp!(inst.file_path, Path.join(copy_dir, "#{inst.sop_instance_uid}.dcm"))
    end)
  end)

# Mode B WADO-RS metadata & frame extraction latency (30 runs)
sample_inst = hd(album_instances)

wado_raw_times =
  for _ <- 1..30 do
    {ms, {:ok, _}} =
      Dia.BenchHelper.time_ms(fn ->
        DicomReader.to_wado_metadata(sample_inst.file_path, "http://localhost:4000/frames/1",
          deidentify: false
        )
      end)

    ms
  end
  |> Enum.sort()

wado_deid_times =
  for _ <- 1..30 do
    {ms, {:ok, _}} =
      Dia.BenchHelper.time_ms(fn ->
        DicomReader.to_wado_metadata(sample_inst.file_path, "http://localhost:4000/frames/1",
          deidentify: true
        )
      end)

    ms
  end
  |> Enum.sort()

frame_times =
  for _ <- 1..30 do
    {ms, {:ok, _}} =
      Dia.BenchHelper.time_ms(fn ->
        DicomReader.extract_frames(sample_inst.file_path, [1])
      end)

    ms
  end
  |> Enum.sort()

# Mode A Kheops STOW-RS publish throughput against in-memory Plug stub (raw vs PS3.15 de-identified)
mock_kheops = fn conn ->
  {:ok, _body, conn} = Plug.Conn.read_body(conn)

  case conn.request_path do
    "/api/albums" ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, Jason.encode!(%{"album_id" => "bench_alb_1"}))

    "/api/studies" ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, "{}")
  end
end

{stow_raw_ms, {:ok, raw_job}} =
  Dia.BenchHelper.time_ms(fn ->
    Publisher.publish_sync(
      album,
      %{
        "kheops_base_url" => "https://kheops.bench.local",
        "kheops_album_name" => "Bench Raw",
        "deidentify" => false
      },
      "bench-token",
      req_options: [plug: mock_kheops]
    )
  end)

{stow_deid_ms, {:ok, deid_job}} =
  Dia.BenchHelper.time_ms(fn ->
    Publisher.publish_sync(
      album,
      %{
        "kheops_base_url" => "https://kheops.bench.local",
        "kheops_album_name" => "Bench DeID",
        "deidentify" => true
      },
      "bench-token",
      req_options: [plug: mock_kheops]
    )
  end)

summary = %{
  album_instances: length(album_instances),
  album_payload_mb: Float.round(album_bytes / 1_048_576, 2),
  zero_copy_album_ms: Float.round(album_ms, 2),
  zero_copy_extra_disk_bytes: 0,
  physical_copy_ms: Float.round(copy_ms, 2),
  physical_copy_extra_disk_bytes: album_bytes,
  wado_meta_raw_p50_ms: Float.round(Dia.BenchHelper.percentile(wado_raw_times, 0.50), 3),
  wado_meta_raw_p95_ms: Float.round(Dia.BenchHelper.percentile(wado_raw_times, 0.95), 3),
  wado_meta_deid_p50_ms: Float.round(Dia.BenchHelper.percentile(wado_deid_times, 0.50), 3),
  wado_meta_deid_p95_ms: Float.round(Dia.BenchHelper.percentile(wado_deid_times, 0.95), 3),
  wado_frame_p50_ms: Float.round(Dia.BenchHelper.percentile(frame_times, 0.50), 3),
  wado_frame_p95_ms: Float.round(Dia.BenchHelper.percentile(frame_times, 0.95), 3),
  stow_raw_instances: raw_job.uploaded_count,
  stow_raw_ms: Float.round(stow_raw_ms, 2),
  stow_raw_fps: Float.round(raw_job.uploaded_count / (stow_raw_ms / 1000.0), 1),
  stow_deid_instances: deid_job.uploaded_count,
  stow_deid_ms: Float.round(stow_deid_ms, 2),
  stow_deid_fps: Float.round(deid_job.uploaded_count / (stow_deid_ms / 1000.0), 1)
}

IO.puts("Album & Sharing Benchmarks: #{Jason.encode!(summary)}")

# Cleanup benchmark DB entries & temp directory so dev database remains clean
Enum.each(results, fn {src, _} -> Catalog.delete_archive_source(src) end)
Albums.delete_album(album)
File.rm_rf!(bench_root)
IO.puts("=== Benchmark cleanup complete ===")
